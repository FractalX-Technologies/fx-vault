import Foundation
import GitHubKit
import VaultCore

/// Hands out Key Vault access tokens (v0.8.0). ``AzureCLITokenProvider`` is the real one.
public protocol AccessTokenProviding: Sendable {
    /// A token for `tenantID` (nil: the account's default tenant). The caller owns the returned
    /// copy and wipes it after use.
    func token(tenantID: String?) async throws(DestinationError) -> SecretBytes
    /// Forgets the cached token for `tenantID` (after a 401), so the next call fetches a new one.
    func invalidate(tenantID: String?) async
}

/// Key Vault tokens from the user's `az login` (v0.8.0, tasks/todo.md R4).
///
/// Runs `<az> account get-access-token --resource https://vault.azure.net [--tenant <id>]
/// --output json` through ``AzureCLIRunner`` with `Timeouts.azAccessToken`.
/// `accessToken` is read with the secret JSON scanner; stdout is wiped.
///
/// Tokens are kept in memory per tenant until `expires_on - Timeouts.accessTokenRefreshMargin`
/// (callers get copies; a replaced or invalidated token is zeroed when its last reference goes);
/// concurrent requests for one tenant share one `az` run. Failures are classified by
/// ``AzureCLIRunner/classify(_:)``.
public actor AzureCLITokenProvider: AccessTokenProviding {
    static let baseArguments = ["account", "get-access-token", "--resource", DestinationConstants.keyVaultResource]
    static let tenantFlag = "--tenant"

    private static let accessTokenField = "accessToken"
    private static let expiresOnEpochField = "expires_on"
    private static let expiresOnTextField = "expiresOn"
    private static let expiresOnFormats = ["yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss"]
    private static let posixLocale = "en_US_POSIX"
    /// The tenant key of the default tenant in the caches.
    private static let defaultTenantKey = ""

    private struct CachedToken: Sendable {
        let token: SecretBytes
        let refreshAt: Date
    }

    private let cli: AzureCLIRunner
    private let clock: any VaultClock
    private var cache: [String: CachedToken] = [:]
    private var pending: [String: Task<Result<CachedToken, DestinationError>, Never>] = [:]

    public init(cli: AzureCLIRunner, clock: any VaultClock) {
        self.cli = cli
        self.clock = clock
    }

    /// Builds its own ``AzureCLIRunner``; kept for callers that have no runner at hand (live tests).
    public init(
        runner: any CommandRunning,
        locator: AzureCLILocator = AzureCLILocator(),
        overridePath: String? = nil,
        identity: ProcessIdentityModel,
        shell: ShellEnvironmentModel,
        workingDirectory: URL,
        azureConfigDirectory: String? = nil,
        clock: any VaultClock
    ) {
        self.init(
            cli: AzureCLIRunner(
                runner: runner,
                locator: locator,
                overridePath: overridePath,
                identity: identity,
                shell: shell,
                workingDirectory: workingDirectory,
                azureConfigDirectory: azureConfigDirectory
            ),
            clock: clock
        )
    }

    public func token(tenantID: String?) async throws(DestinationError) -> SecretBytes {
        let key = tenantID ?? Self.defaultTenantKey
        if let cached = cache[key], clock.now < cached.refreshAt {
            return cached.token.copy()
        }
        if let running = pending[key] {
            return try await running.value.get().token.copy()
        }
        let task = Task { await self.fetch(tenantID: tenantID) }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        let entry = try result.get()
        cache[key] = entry
        return entry.token.copy()
    }

    /// Drops the cached token. It is not wiped here because a caller that joined the same `az`
    /// run may still be copying it; `SecretBytes` zeroes it when the last reference goes.
    public func invalidate(tenantID: String?) {
        cache[tenantID ?? Self.defaultTenantKey] = nil
    }

    // MARK: - Running az

    private func fetch(tenantID: String?) async -> Result<CachedToken, DestinationError> {
        do throws(DestinationError) {
            let arguments = try Self.arguments(tenantID: tenantID)
            let stdout = try await cli.run(arguments, timeout: Timeouts.azAccessToken)
            defer { stdout.wipe() }
            let parsed = try Self.parse(stdout: stdout)
            return .success(CachedToken(token: parsed.token, refreshAt: parsed.expiresAt - Timeouts.accessTokenRefreshMargin.timeInterval))
        } catch {
            return .failure(error)
        }
    }

    /// The argv after the `az` path. Throws ``DestinationError/invalidInput(_:)`` for a tenant
    /// that is not a tenant id or domain (so it can never become a flag).
    static func arguments(tenantID: String?) throws(DestinationError) -> [String] {
        var arguments = baseArguments
        if let tenantID {
            guard DestinationRules.isValidTenantID(tenantID) else {
                throw .invalidInput(.invalidDestinationTarget(.tenantID))
            }
            arguments += [tenantFlag, tenantID]
        }
        return arguments + AzureCLIRunner.outputArguments
    }

    /// Reads `accessToken` (as `SecretBytes`) and its expiry: `expires_on` (unix seconds, a
    /// number or text) or, from older `az`, `expiresOn` (local time without a zone).
    static func parse(
        stdout: SecretBytes,
        timeZone: TimeZone = .current
    ) throws(DestinationError) -> (token: SecretBytes, expiresAt: Date) {
        let document = try SecretJSONDocument(parsing: stdout)
        guard let token = document.secret(.key(accessTokenField)) else { throw .decoding }
        guard BearerToken.isUsable(token) else {
            token.wipe()
            throw .decoding
        }
        if let epoch = document.integer(.key(expiresOnEpochField))
            ?? document.string(.key(expiresOnEpochField)).flatMap({ Int64($0) })
        {
            return (token, Date(timeIntervalSince1970: TimeInterval(epoch)))
        }
        if let text = document.string(.key(expiresOnTextField)), let date = localDate(text, timeZone: timeZone) {
            return (token, date)
        }
        token.wipe()
        throw .decoding
    }

    private static func localDate(_ text: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: posixLocale)
        formatter.timeZone = timeZone
        for format in expiresOnFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
    }
}
