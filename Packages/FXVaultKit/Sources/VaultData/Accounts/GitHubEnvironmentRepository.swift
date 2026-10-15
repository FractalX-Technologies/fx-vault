import Foundation
import GitHubKit
import os
import VaultCore
import VaultStore

/// The local GitHub environment: the gh binary, the logged-in accounts with their scopes, the
/// per-account gh queues and tokens, and the SSH alias of each account (§2, §5.10, §8 A, D1–D2;
/// D5, D19; M2).
///
/// - **gh detection** (``detectGH(overridePath:)``): the login-shell probe (A2, once, cached) then
///   `GHLocator` (override path, Homebrew, shell PATH, MacPorts/Nix/`~/.local`, trust checks,
///   version floor 2.97.0).
/// - **Accounts** (``accounts()``): A3 through `GHAuthService`, persisted to `accounts` (new
///   logins inserted, presence updated, rows kept for their repositories) with each token's
///   `ScopeStatus`.
/// - **Tokens**: memory only (`GHTokenCache`). ``purgeTokens()`` is synchronous and nonisolated
///   so the lock path (`VaultManager(onLock:)`) can call it; **Re-check** invalidates one login.
/// - **Queues** (``scheduler(for:)``): one `GHCommandScheduler` per account, seeded with the
///   journal's writes of the last hour (D12).
/// - **SSH aliases**: listed from `~/.ssh/config`, mapped manually per account
///   (``mapSSHAlias(_:to:)``) and checked with **Test** (``testSSHAlias(_:for:)``: `ssh -G` must
///   resolve to github.com, then `ssh -T` names the authenticated login).
public actor GitHubEnvironmentRepository: GHSchedulerProviding {
    /// The token cache shared by every scheduler; purged on lock.
    public nonisolated let tokenCache: GHTokenCache
    private let database: VaultDatabase
    private let runner: any CommandRunning
    private let identity: ProcessIdentityModel
    private let workingDirectory: URL
    private let clock: any VaultClock
    private let shellPath: String?
    private let sshParser: SSHConfigParser
    private var shell: ShellEnvironmentModel?
    /// The gh binary found by the last successful ``detectGH(overridePath:)``.
    public private(set) var installation: GHInstallationModel?
    private var schedulers: [String: GHCommandScheduler] = [:]
    private var lastStatuses: [GHAccountStatusModel] = []

    private static let log = Logger(subsystem: ConfigConstants.logSubsystem, category: "github-environment")

    /// - Parameters:
    ///   - runner: `ProcessRunner` in the app, `FakeCommandRunner` in tests and previews.
    ///   - workingDirectory: `EmptyWorkingDirectory.prepareDefault()`.
    ///   - shellPath: the login shell to probe; nil reads it from the password database.
    ///   - sshConfigParser: nil reads `~/.ssh/config` of `identity`.
    public init(
        database: VaultDatabase,
        runner: any CommandRunning,
        identity: ProcessIdentityModel,
        workingDirectory: URL,
        clock: any VaultClock = SystemClock(),
        tokenCache: GHTokenCache = GHTokenCache(),
        shellPath: String? = nil,
        sshConfigParser: SSHConfigParser? = nil
    ) {
        self.database = database
        self.runner = runner
        self.identity = identity
        self.workingDirectory = workingDirectory
        self.clock = clock
        self.tokenCache = tokenCache
        self.shellPath = shellPath
        sshParser = sshConfigParser ?? SSHConfigParser.forUser(identity)
    }

    // MARK: - gh detection

    /// The allowlisted login-shell environment (A2), probed once and cached. Pass `refresh` to
    /// probe again (Preferences › Advanced "Check again").
    public func shellEnvironment(refresh: Bool = false) async throws(GitHubEnvironmentError) -> ShellEnvironmentModel {
        if let shell, !refresh { return shell }
        let resolver = ShellEnvironmentResolver(
            runner: runner,
            identity: identity,
            workingDirectory: workingDirectory,
            shellPath: shellPath
        )
        do {
            let resolved = try await resolver.resolve()
            shell = resolved
            return resolved
        } catch {
            throw .github(.cancelled)
        }
    }

    /// Finds a trusted gh at or above the 2.97.0 floor (D5). A changed binary drops the cached
    /// queues, which are rebuilt (and re-seeded) on next use.
    ///
    /// - Throws: `.github(.notInstalled)`, `.github(.untrustedBinary(path:))`,
    ///   `.github(.versionTooOld(found:required:))`, `.github(.malformedOutput)`.
    @discardableResult
    public func detectGH(overridePath: String? = nil) async throws(GitHubEnvironmentError) -> GHInstallationModel {
        let shell = try await shellEnvironment()
        let locator = GHLocator(runner: runner, identity: identity, workingDirectory: workingDirectory)
        do {
            let found = try await locator.locate(overridePath: overridePath, shell: shell)
            if installation?.resolvedPath != found.resolvedPath {
                schedulers.removeAll()
            }
            installation = found
            return found
        } catch {
            installation = nil
            schedulers.removeAll()
            throw .github(error)
        }
    }

    // MARK: - Accounts

    /// The github.com accounts gh knows, merged with the stored rows (A3). New logins are
    /// inserted, every row's presence is updated, and rows gh no longer lists stay (with a nil
    /// ``GHAccountSummaryModel/status``) for their repositories.
    public func accounts() async throws(GitHubEnvironmentError) -> [GHAccountSummaryModel] {
        let auth = try authService()
        let statuses: [GHAccountStatusModel]
        do {
            statuses = try await auth.accounts()
        } catch {
            throw .github(error)
        }
        lastStatuses = statuses
        let now = clock.now
        let store = AccountStore(database: database)
        let stored: [AccountModel]
        do {
            stored = try database.write { tx in
                for status in statuses {
                    var account = try store.fetch(login: status.login, in: tx) ?? AccountModel(login: status.login, lastSeenAt: now)
                    account.isPresent = true
                    account.lastSeenAt = now
                    try store.save(account, in: tx)
                }
                try store.updatePresence(presentLogins: Set(statuses.map(\.login)), now: now, in: tx)
                return try store.fetchAll(in: tx)
            }
        } catch {
            throw .wrap(error)
        }
        let statusByID = Dictionary(statuses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        Self.log.info("gh lists \(statuses.count, privacy: .public) account(s)")
        return stored.map { GHAccountSummaryModel(account: $0, status: statusByID[$0.id]) }
    }

    /// **Re-check** (§10 Preferences › Accounts): forgets `login`'s cached token so the next
    /// call runs A4 again, then reloads the accounts.
    public func recheck(login: String) async throws(GitHubEnvironmentError) -> [GHAccountSummaryModel] {
        tokenCache.invalidate(login: login)
        return try await accounts()
    }

    /// The copyable commands that add the missing scopes to `login` (§2): switch to it,
    /// refresh, and switch back to the account that was active at the last ``accounts()``.
    public func scopeFixCommands(for login: String) -> [String] {
        let active = lastStatuses.first(where: \.isActive)?.login
        return ScopeChecker.fixCommands(login: login, previousActiveLogin: active)
    }

    /// Wipes every cached token. Synchronous: call it from the lock path (§5.8 Phase A).
    public nonisolated func purgeTokens() {
        tokenCache.purge()
    }

    // MARK: - Queues

    /// The account's serial gh queue (D12), created on first use and seeded with the journal's
    /// writes of the last hour.
    ///
    /// - Throws: `.notInstalled` until ``detectGH(overridePath:)`` succeeded.
    public func scheduler(for accountLogin: String) async throws(GHError) -> GHCommandScheduler {
        let key = OwnerLoginValidator.foldKey(accountLogin)
        if let existing = schedulers[key] { return existing }
        let auth: GHAuthService
        do {
            auth = try authService()
        } catch {
            throw Self.ghError(from: error)
        }
        let service = try commandService()
        let scheduler = GHCommandScheduler(accountLogin: accountLogin, service: service, auth: auth, clock: clock)
        // Stored before the first suspension, so concurrent callers share one queue.
        schedulers[key] = scheduler
        await scheduler.seed(recentWrites: recentWrites(accountLogin: accountLogin))
        return scheduler
    }

    // MARK: - SSH aliases

    /// The concrete `Host` aliases of `~/.ssh/config` and its includes (the alias picker).
    public nonisolated func sshHostEntries() -> [SSHHostEntryModel] {
        sshParser.parseUserConfig()
    }

    /// Maps `alias` to the account (nil removes the mapping). The previous verification is
    /// cleared: press **Test** again.
    ///
    /// - Throws: `.ssh(.invalidAlias)`, `.accountNotFound`, `.store`.
    @discardableResult
    public func mapSSHAlias(_ alias: String?, to login: String) throws(GitHubEnvironmentError) -> AccountModel {
        let validAlias: String?
        do {
            validAlias = try alias.map { alias throws(GitError) in try SSHAliasValidator.validate(alias) }
        } catch {
            throw .ssh(error)
        }
        return try updateAccount(login) { account in
            account.sshHostAlias = validAlias
            account.sshVerifiedLogin = nil
            account.sshVerifiedAt = nil
        }
    }

    /// **Test** (D19): `ssh -G` must resolve `alias` to github.com, then `ssh -T` reports which
    /// login the key authenticates as. When `alias` is the account's mapped alias, the
    /// verified login and time are stored (cleared on any other outcome).
    public func testSSHAlias(_ alias: String, for login: String) async throws(GitHubEnvironmentError)
        -> SSHAliasTestResultModel
    {
        let shell = try await shellEnvironment()
        let resolver = SSHAliasResolver(runner: runner, identity: identity, shell: shell, workingDirectory: workingDirectory)
        let result: SSHAliasTestResultModel
        do {
            let hostName = try await resolver.resolveHostName(alias: alias)
            if hostName.lowercased() != GHConstants.host {
                result = .notGitHub(hostName: hostName)
            } else {
                result = classify(try await resolver.verify(alias: alias), expectedLogin: login)
            }
        } catch .timeout {
            result = .timeout
        } catch .commandFailed(let exitCode) {
            result = .failed(exitCode: exitCode)
        } catch {
            throw .ssh(error)
        }
        try recordVerification(result, alias: alias, login: login)
        return result
    }

    // MARK: - Private

    private func commandService() throws(GHError) -> GHCommandService {
        guard let installation else { throw .notInstalled }
        return GHCommandService(
            installation: installation,
            identity: identity,
            shell: shell ?? .empty,
            workingDirectory: workingDirectory,
            runner: runner
        )
    }

    private func authService() throws(GitHubEnvironmentError) -> GHAuthService {
        do {
            return GHAuthService(service: try commandService(), tokenCache: tokenCache)
        } catch {
            throw .github(error)
        }
    }

    private static func ghError(from error: GitHubEnvironmentError) -> GHError {
        if case .github(let error) = error { return error }
        return .launchFailed
    }

    /// The journal's write starts of the last hour, each at the default cost. A database
    /// failure only loses the seed (logged), never the queue.
    private func recentWrites(accountLogin: String) -> [GHWriteRecordModel] {
        let since = clock.now.addingTimeInterval(-Timeouts.throttleHourWindow.timeInterval)
        do {
            return try SyncJournalStore(database: database)
                .writeStartTimes(accountLogin: accountLogin, since: since)
                .map { GHWriteRecordModel(date: $0, cost: Limits.defaultWriteCost) }
        } catch {
            Self.log.error("Could not seed the write throttle from the journal")
            return []
        }
    }

    private func classify(_ verification: SSHAliasVerificationModel, expectedLogin: String) -> SSHAliasTestResultModel {
        switch verification {
        case .authenticated(let login):
            if OwnerLoginValidator.foldKey(login) == OwnerLoginValidator.foldKey(expectedLogin) {
                return .authenticatedAsAccount(login: login)
            }
            let known = lastStatuses.contains { $0.id == OwnerLoginValidator.foldKey(login) }
            return .authenticatedAsOtherAccount(login: login, isLoggedIntoGH: known)
        case .permissionDenied: return .permissionDenied
        case .hostKeyUnknown: return .hostKeyUnknown
        case .timeout: return .timeout
        case .failed(let exitCode): return .failed(exitCode: exitCode)
        }
    }

    private func recordVerification(_ result: SSHAliasTestResultModel, alias: String, login: String) throws(GitHubEnvironmentError) {
        let store = AccountStore(database: database)
        let account: AccountModel?
        do {
            account = try store.fetch(login: login)
        } catch {
            throw .wrap(error)
        }
        guard let account, account.sshHostAlias == alias else { return }
        let now = clock.now
        try updateAccount(login) { account in
            if case .authenticatedAsAccount(let verified) = result {
                account.sshVerifiedLogin = verified
                account.sshVerifiedAt = now
            } else {
                account.sshVerifiedLogin = nil
                account.sshVerifiedAt = nil
            }
        }
    }

    @discardableResult
    private func updateAccount(
        _ login: String,
        _ change: (inout AccountModel) -> Void
    ) throws(GitHubEnvironmentError) -> AccountModel {
        let store = AccountStore(database: database)
        do {
            return try database.write { tx in
                guard var account = try store.fetch(login: login, in: tx) else {
                    throw GitHubEnvironmentError.accountNotFound
                }
                change(&account)
                try store.save(account, in: tx)
                return account
            }
        } catch {
            throw .wrap(error)
        }
    }
}
