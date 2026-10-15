import EnvTools
import Foundation
import FXVaultTestSupport
import GitHubKit
import os
import SyncEngine
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

/// Opt-in end-to-end checks against the real gh and the real GitHub (tasks/todo.md §11 M3 spike,
/// §12). Never enabled in CI.
///
/// | Variable | Effect |
/// |---|---|
/// | `FXV_LIVE_E2E=1` | Runs the read-only suite (discovery, catalog, import of a public repository, clone, `.env` export). Writes nothing to GitHub. |
/// | `FXV_LIVE_E2E_WRITE=1` | Also runs the write scenario on `<account>/fx-vault-e2e` (a **public** repository it creates when missing). Needs the maintainer's approval of that repository. |
/// | `FXV_LIVE_E2E_FREE_ORG=<org>` | Also runs the plan-gated scenario on `<org>/fx-vault-e2e-free` (a **private** repository on a Free organization). |
/// | `FXV_LIVE_E2E_SSH_ALIAS` | The SSH alias of the account (default `github.com`). |
/// | `FXV_LIVE_E2E_READ_REPO` | The public repository the read-only import reads (default `cli/cli`). |
/// | `FXV_LIVE_E2E_CLONE_REPO` | The small public repository the read-only clone fetches (default `octocat/Hello-World`). |
/// | `FXV_LIVE_E2E_REPORT` | A file the observed gh behavior is written to as JSON (owner and repository names replaced by placeholders). |
///
/// Every value written is synthetic (`FXV_E2E_*`). No assertion message contains a value or a
/// token. Repositories cannot be deleted (the token has no `delete_repo` scope): the write
/// scenario removes what it created inside them and leaves the repositories for the maintainer to delete.
enum LiveE2E {
    static let environment = ProcessInfo.processInfo.environment

    static var isEnabled: Bool {
        environment["FXV_LIVE_E2E"] == "1"
    }

    static var isWriteEnabled: Bool {
        isEnabled && environment["FXV_LIVE_E2E_WRITE"] == "1"
    }

    static var freeOrganization: String? {
        guard isWriteEnabled, let org = environment["FXV_LIVE_E2E_FREE_ORG"], !org.isEmpty else { return nil }
        return org
    }

    static var sshAlias: String {
        environment["FXV_LIVE_E2E_SSH_ALIAS"] ?? "github.com"
    }

    static var readRepository: String {
        environment["FXV_LIVE_E2E_READ_REPO"] ?? "cli/cli"
    }

    static var cloneRepository: String {
        environment["FXV_LIVE_E2E_CLONE_REPO"] ?? "octocat/Hello-World"
    }

    static var reportURL: URL? {
        environment["FXV_LIVE_E2E_REPORT"].map { URL(fileURLWithPath: $0) }
    }

    /// The scenario repositories (§11 M3 spike, renamed for this suite).
    static let publicRepositoryName = "fx-vault-e2e"
    static let freeRepositoryName = "fx-vault-e2e-free"

    /// What a Finder launch gives the app: launchd's minimal PATH and the agent socket, nothing
    /// from a login shell.
    static var finderEnvironment: [String: String] {
        var minimal = ["PATH": "/usr/bin:/bin"]
        minimal[ProcessEnvironmentBuilder.Key.sshAuthSock] = environment[ProcessEnvironmentBuilder.Key.sshAuthSock]
        return minimal
    }

    static let password = "violet harbor quartz lantern meadow anchor"

    /// GitHub lists `updatedAt` with whole seconds: two writes of one item less than a second
    /// apart can show the same timestamp, so the scenario waits this long between them.
    static let timestampTick: Duration = .milliseconds(1_500)
}

// MARK: - Independent gh calls

/// One raw gh call's outcome. `stdout` may hold synthetic variable values; never put it in an
/// assertion message.
struct GHProbeResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var isSuccess: Bool {
        exitCode == 0
    }
}

/// Raw gh calls that check GitHub independently of the engine (and play the teammate in the
/// drift step). Values go on stdin only, like the app does. Runs through any `CommandRunning`,
/// so the same scenario also runs against `GitHubSimulator`.
struct GHProbe: Sendable {
    let runner: any CommandRunning
    let executableURL: URL
    let environment: [String: String]
    let workingDirectory: URL

    static let apiHeaders = [
        "-H", "Accept: \(GHConstants.acceptHeader)",
        "-H", "X-GitHub-Api-Version: \(GHConstants.apiVersion)",
    ]

    func run(_ arguments: [String], stdin: String? = nil) async throws -> GHProbeResult {
        let payload = stdin.map { StdinPayload(transferring: SecretBytes(utf8: $0)) } ?? .empty
        let spec = CommandSpec(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            stdin: payload,
            timeout: Timeouts.ghRepoList
        )
        let result = try await runner.run(spec)
        defer { result.stdout.wipe() }
        let stdout = result.stdout.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        return GHProbeResult(exitCode: result.exitCode, stdout: stdout, stderr: result.stderr)
    }

    /// `gh api -X GET <path> --paginate --slurp`, decoded.
    func apiPages(_ path: String) async throws -> [[String: Any]] {
        let result = try await run(["api"] + Self.apiHeaders + ["-X", "GET", path, "--paginate", "--slurp"])
        try #require(result.isSuccess, "gh api GET failed: \(StderrRedactor.redactTokenPatterns(in: result.stderr))")
        return try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]])
    }

    func repositoryExists(_ fullName: String) async throws -> Bool {
        let result = try await run(["repo", "view", fullName, "--json", "name"])
        if result.isSuccess { return true }
        let error = GHStderrClassifier.classify(GHFailureContext(
            operation: .repoView,
            exitCode: result.exitCode,
            stderr: StderrRedactor.redactTokenPatterns(in: result.stderr)
        ))
        try #require(error == .notFound, "gh repo view failed: \(error.logCode)")
        return false
    }

    /// Secret names and `updatedAt` of a scope.
    func secrets(_ fullName: String, environment: String? = nil) async throws -> [String: String] {
        let rows = try await listJSON(["secret", "list", "--repo=\(fullName)"] + Self.envFlag(environment) + ["--json", "name,updatedAt"])
        return Dictionary(rows.compactMap { row in
            (row["name"] as? String).map { ($0, row["updatedAt"] as? String ?? "") }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Variable names and values of a scope (synthetic values only).
    func variables(_ fullName: String, environment: String? = nil) async throws -> [String: String] {
        let rows = try await listJSON(["variable", "list", "--repo=\(fullName)"] + Self.envFlag(environment) + ["--json", "name,value"])
        return Dictionary(rows.compactMap { row in
            guard let name = row["name"] as? String, let value = row["value"] as? String else { return nil }
            return (name, value)
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Variable `updatedAt` by name.
    func variableTimestamps(_ fullName: String, environment: String? = nil) async throws -> [String: String] {
        let rows = try await listJSON(["variable", "list", "--repo=\(fullName)"] + Self.envFlag(environment) + ["--json", "name,updatedAt"])
        return Dictionary(rows.compactMap { row in
            (row["name"] as? String).map { ($0, row["updatedAt"] as? String ?? "") }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Environments by name with their `deployment_branch_policy` flags (nil: all branches).
    func environments(_ fullName: String) async throws -> [String: (protected: Bool, custom: Bool)?] {
        var result: [String: (protected: Bool, custom: Bool)?] = [:]
        for page in try await apiPages("repos/\(fullName)/environments") {
            for environment in page["environments"] as? [[String: Any]] ?? [] {
                guard let name = environment["name"] as? String else { continue }
                if let policy = environment["deployment_branch_policy"] as? [String: Any] {
                    result[name] = (policy["protected_branches"] as? Bool ?? false, policy["custom_branch_policies"] as? Bool ?? false)
                } else {
                    result[name] = .some(nil)
                }
            }
        }
        return result
    }

    /// `name|type` of every deployment branch policy of an environment.
    func branchPolicies(_ fullName: String, environment: String) async throws -> Set<String> {
        let path = "repos/\(fullName)/environments/\(environment)/deployment-branch-policies"
        var result: Set<String> = []
        for page in try await apiPages(path) {
            for policy in page["branch_policies"] as? [[String: Any]] ?? [] {
                result.insert("\(policy["name"] as? String ?? "")|\(policy["type"] as? String ?? "branch")")
            }
        }
        return result
    }

    private func listJSON(_ arguments: [String]) async throws -> [[String: Any]] {
        let result = try await run(arguments)
        try #require(result.isSuccess, "gh \(arguments.prefix(2).joined(separator: " ")) failed: \(StderrRedactor.redactTokenPatterns(in: result.stderr))")
        return try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]])
    }

    private static func envFlag(_ environment: String?) -> [String] {
        environment.map { ["--env=\($0)"] } ?? []
    }
}

// MARK: - Observed behavior report

/// Spike facts and gh stderr seen during a live run, written to `FXV_LIVE_E2E_REPORT` with the
/// real owner and repository names replaced (the repository is public).
final class LiveE2EReport: Sendable {
    private let entries = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    private let replacements: [(String, String)]

    init(replacements: [(String, String)]) {
        self.replacements = replacements
    }

    func record(_ key: String, _ value: String) {
        entries.withLock { $0[key] = sanitize(value) }
    }

    func sanitize(_ text: String) -> String {
        var result = StderrRedactor.redactTokenPatterns(in: text)
        for (real, placeholder) in replacements where !real.isEmpty {
            result = result.replacingOccurrences(of: real, with: placeholder, options: .caseInsensitive)
        }
        return result
    }

    var snapshot: [String: String] {
        entries.withLock { $0 }
    }

    func write() {
        guard let url = LiveE2E.reportURL,
              let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: url)
    }
}

// MARK: - The world

/// A vault on disk (`KDFPolicy.testing`) wired to a GitHub: the real gh in live mode, the
/// `GitHubSimulator` in the dry run. The scenario code is the same for both.
struct E2EWorld {
    let directory: VaultTemporaryDirectory
    let database: VaultDatabase
    let session: VaultSession
    let manager: VaultManager
    let clock: any VaultClock
    let schedulers: any GHSchedulerProviding
    let probe: GHProbe
    let git: GitService
    let accountLogin: String
    let config: ConfigRepository
    let catalog: RepoCatalogRepository
    let creation: RepoCreationRepository
    let sync: SyncRepository
    let drift: DriftRepository
    let envFiles: EnvFileRepository
    /// Live mode only.
    let github: GitHubEnvironmentRepository?
    /// Dry run only.
    let simulator: GitHubSimulator?

    var isLive: Bool {
        github != nil
    }

    /// The real stack, as a Finder launch would build it: no inherited PATH, the login-shell
    /// probe, `GHLocator`, `gh auth status`.
    static func live() async throws -> E2EWorld {
        let directory = try VaultTemporaryDirectory()
        let caches = directory.directory("caches")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let database = try DatabaseFactory.openOnDisk(directory: directory.directory("vault"))
        let session = VaultSession(database: database)
        let manager = try VaultManager(
            session: session,
            policy: .testing,
            biometricStore: FakeBiometricKeyStore(),
            capabilities: FakeBuildCapabilities()
        )
        _ = try await manager.create(password: LiveE2E.password)
        let runner = ProcessRunner()
        let identity = ProcessIdentityModel.current(processEnvironment: LiveE2E.finderEnvironment)
        let workingDirectory = try EmptyWorkingDirectory.prepare(in: caches)
        let clock = SystemClock()
        let github = GitHubEnvironmentRepository(
            database: database,
            runner: runner,
            identity: identity,
            workingDirectory: workingDirectory,
            clock: clock
        )
        let installation = try await github.detectGH()
        let accounts = try await github.accounts()
        let active = try #require(accounts.first { $0.status?.isActive == true }, "gh has no active github.com account")
        let shell = try await github.shellEnvironment()
        let git = GitService(runner: runner, identity: identity, shell: shell, workingDirectory: workingDirectory, clock: clock)
        let probe = GHProbe(
            runner: runner,
            executableURL: URL(fileURLWithPath: installation.path),
            environment: try ProcessEnvironmentBuilder.gh(identity: identity, shell: shell, token: nil),
            workingDirectory: workingDirectory
        )
        return make(
            directory: directory,
            database: database,
            session: session,
            manager: manager,
            clock: clock,
            schedulers: github,
            probe: probe,
            git: git,
            accountLogin: active.status?.login ?? active.account.login,
            github: github,
            simulator: nil
        )
    }

    /// The dry run: the same scenario against `GitHubSimulator` (owner `user-a`), with a git
    /// runner that only creates the clone directory.
    static func simulated(_ simulator: GitHubSimulator) async throws -> E2EWorld {
        let directory = try VaultTemporaryDirectory()
        let database = try DatabaseFactory.openOnDisk(directory: directory.directory("vault"))
        let session = VaultSession(database: database)
        let manager = try VaultManager(
            session: session,
            policy: .testing,
            biometricStore: FakeBiometricKeyStore(),
            capabilities: FakeBuildCapabilities(),
            clock: ManualClock()
        )
        _ = try await manager.create(password: LiveE2E.password)
        let clock = SteppingClock()
        let schedulers = SimulatorSchedulerProvider(runner: simulator, clock: clock)
        let git = GitService(
            runner: CloningRunner(),
            identity: GHFixtures.identity,
            shell: .empty,
            workingDirectory: GHFixtures.workingDirectory,
            clock: clock
        )
        let probe = GHProbe(
            runner: simulator,
            executableURL: GHFixtures.ghURL,
            environment: [:],
            workingDirectory: GHFixtures.workingDirectory
        )
        try AccountStore(database: database).save(AccountModel(login: SyncFixture.login, lastSeenAt: clock.now))
        return make(
            directory: directory,
            database: database,
            session: session,
            manager: manager,
            clock: clock,
            schedulers: schedulers,
            probe: probe,
            git: git,
            accountLogin: SyncFixture.login,
            github: nil,
            simulator: simulator
        )
    }

    private static func make(
        directory: VaultTemporaryDirectory,
        database: VaultDatabase,
        session: VaultSession,
        manager: VaultManager,
        clock: any VaultClock,
        schedulers: any GHSchedulerProviding,
        probe: GHProbe,
        git: GitService,
        accountLogin: String,
        github: GitHubEnvironmentRepository?,
        simulator: GitHubSimulator?
    ) -> E2EWorld {
        let creation = RepoCreationRepository(session: session, schedulers: schedulers, git: git, clock: clock)
        return E2EWorld(
            directory: directory,
            database: database,
            session: session,
            manager: manager,
            clock: clock,
            schedulers: schedulers,
            probe: probe,
            git: git,
            accountLogin: accountLogin,
            config: ConfigRepository(session: session, clock: clock),
            catalog: RepoCatalogRepository(session: session, schedulers: schedulers, clock: clock),
            creation: creation,
            sync: SyncRepository(session: session, schedulers: schedulers, cloner: creation, clock: clock),
            drift: DriftRepository(session: session, schedulers: schedulers, clock: clock),
            envFiles: EnvFileRepository(
                session: session,
                gitignoreChecker: GitServiceGitignoreChecker(git: git),
                clock: clock
            ),
            github: github,
            simulator: simulator
        )
    }

    func remove() {
        directory.remove()
    }

    // MARK: - Vault reads

    var store: ConfigStore {
        ConfigStore(database: database)
    }

    func repository(_ fullName: String) throws -> RepoModel {
        let ref = try GHRepoRef(fullName: fullName)
        return try #require(try RepoStore(database: database).fetch(ownerLogin: ref.owner, name: ref.name))
    }

    func environment(_ name: String, in repositoryID: RepoID) throws -> EnvironmentModel? {
        try store.fetchEnvironments(repositoryID: repositoryID).first {
            !$0.isDeleted && $0.nameKey == EnvironmentNameValidator.foldKey(name)
        }
    }

    func liveItems(_ repositoryID: RepoID, scope: ConfigScope) throws -> [ConfigItemState] {
        try store.fetchItemStates(repositoryID: repositoryID, scope: scope).filter { !$0.isDeleted }
    }

    func item(_ name: String, kind: ConfigKind, in repositoryID: RepoID, scope: ConfigScope = .repository) throws -> ConfigItemState {
        try #require(try liveItems(repositoryID, scope: scope).first { $0.kind == kind && $0.name == name }, "no row \(name)")
    }

    func pendingCount() throws -> Int {
        try sync.pendingSummary().pendingCount
    }

    /// Preflight, run and wait.
    func runSync(includeDeletions: Bool = true, cloneFolder: URL? = nil) async throws -> SyncRunOutcomeModel {
        let review = try await sync.preflight()
        let handle = try await sync.startRun(review, includeDeletions: includeDeletions, cloneFolder: cloneFolder)
        return await handle.outcome()
    }

    /// The value as stored locally (synthetic data).
    func localValue(_ id: ConfigItemID) throws -> String? {
        do {
            let value = try config.reveal(id)
            defer { value.wipe() }
            return value.utf8String()
        } catch .valueMissing {
            return nil
        }
    }
}

/// Fails the test with the names (never the values) of changes that did not succeed.
func expectClean(_ outcome: SyncRunOutcomeModel, _ step: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let problems = outcome.result.entries.filter { !$0.outcome.isSucceeded }
    #expect(outcome.result.stopReason == nil, "\(step): run stopped (\(String(describing: outcome.result.stopReason)))", sourceLocation: sourceLocation)
    #expect(
        problems.isEmpty,
        "\(step): \(problems.map { "\($0.change.id) → \($0.outcome)" })",
        sourceLocation: sourceLocation
    )
}
