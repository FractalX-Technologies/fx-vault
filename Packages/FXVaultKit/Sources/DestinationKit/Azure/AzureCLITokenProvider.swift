import Darwin
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
/// --output json` through `CommandRunning`: the absolute path of a trusted `az`
/// (``AzureCLILocator``, checked again before every run), an argv array, empty stdin,
/// `Timeouts.azAccessToken`, and exactly the environment of ``environment(identity:shell:azureConfigDirectory:)``.
/// `accessToken` is read with the secret JSON scanner; stdout is wiped.
///
/// Tokens are kept in memory per tenant until `expires_on - Timeouts.accessTokenRefreshMargin`
/// (callers get copies; a replaced or invalidated token is zeroed when its last reference goes);
/// concurrent requests for one tenant share one `az` run. Failures are classified from stderr
/// after token patterns are redacted: "az login" → ``DestinationError/azNotSignedIn``, anything
/// else → ``DestinationError/azFailed(exitCode:)``.
public actor AzureCLITokenProvider: AccessTokenProviding {
    /// The `exitCode` of ``DestinationError/azFailed(exitCode:)`` when `az` could not start.
    public static let launchFailedExitCode: Int32 = -1

    static let baseArguments = ["account", "get-access-token", "--resource", DestinationConstants.keyVaultResource]
    static let tenantFlag = "--tenant"
    static let outputArguments = ["--output", "json"]

    /// Environment variable names `az` receives.
    public enum Key {
        public static let home = ProcessEnvironmentBuilder.Key.home
        public static let path = ProcessEnvironmentBuilder.Key.path
        public static let lang = ProcessEnvironmentBuilder.Key.lang
        public static let tmpdir = ProcessEnvironmentBuilder.Key.tmpdir
        public static let azureConfigDir = "AZURE_CONFIG_DIR"
        public static let collectTelemetry = "AZURE_CORE_COLLECT_TELEMETRY"
        public static let noColor = "AZURE_CORE_NO_COLOR"
        public static let onlyShowErrors = "AZURE_CORE_ONLY_SHOW_ERRORS"
    }

    private static let telemetryOff = "no"
    private static let enabled = "true"
    private static let signInHint = "az login"
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

    private let runner: any CommandRunning
    private let locator: AzureCLILocator
    private let overridePath: String?
    private let identity: ProcessIdentityModel
    private let shell: ShellEnvironmentModel
    private let workingDirectory: URL
    private let azureConfigDirectory: String?
    private let clock: any VaultClock
    private var cache: [String: CachedToken] = [:]
    private var pending: [String: Task<Result<CachedToken, DestinationError>, Never>] = [:]

    /// - Parameters:
    ///   - overridePath: the user's `az` path (then the only candidate), or nil.
    ///   - shell: the probed login-shell environment; its PATH is searched and passed to `az`.
    ///   - workingDirectory: the empty working directory every child starts in.
    ///   - azureConfigDirectory: `AZURE_CONFIG_DIR` to pass, or nil for `az`'s default.
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
        self.runner = runner
        self.locator = locator
        self.overridePath = overridePath
        self.identity = identity
        self.shell = shell
        self.workingDirectory = workingDirectory
        self.azureConfigDirectory = azureConfigDirectory
        self.clock = clock
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
            let installation = try locator.locate(overridePath: overridePath, shell: shell, home: identity.home)
            let spec = CommandSpec(
                executableURL: URL(fileURLWithPath: installation.resolvedPath),
                arguments: arguments,
                environment: Self.environment(identity: identity, shell: shell, azureConfigDirectory: azureConfigDirectory),
                workingDirectory: workingDirectory,
                stdin: .empty,
                timeout: Timeouts.azAccessToken
            )
            let result: CommandResult
            do {
                result = try await runner.run(spec)
            } catch .cancelled {
                throw .cancelled
            } catch .launchFailed(let code) where code == ENOENT {
                throw .azNotInstalled
            } catch {
                throw .azFailed(exitCode: Self.launchFailedExitCode)
            }
            defer { result.stdout.wipe() }
            guard result.isSuccess else { throw Self.classify(result) }
            let parsed = try Self.parse(stdout: result.stdout)
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
        return arguments + outputArguments
    }

    /// The complete environment of `az`: HOME, PATH (the shell's), `LANG=en_US.UTF-8`, TMPDIR
    /// when known, `AZURE_CONFIG_DIR` when given, and telemetry, color and progress output off.
    /// Nothing else is inherited.
    static func environment(
        identity: ProcessIdentityModel,
        shell: ShellEnvironmentModel,
        azureConfigDirectory: String?
    ) -> [String: String] {
        var environment = [
            Key.home: identity.home,
            Key.path: shell.resolvedPATH,
            Key.lang: GHConstants.processLanguage,
            Key.collectTelemetry: telemetryOff,
            Key.noColor: enabled,
            Key.onlyShowErrors: enabled,
        ]
        if !identity.temporaryDirectory.isEmpty {
            environment[Key.tmpdir] = identity.temporaryDirectory
        }
        if let azureConfigDirectory, !azureConfigDirectory.isEmpty {
            environment[Key.azureConfigDir] = azureConfigDirectory
        }
        return environment
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

    /// Classifies a failed run. Timeouts are ``DestinationError/timeout``; stderr is classified
    /// only after token patterns are redacted (tasks/lessons.md, "Redact for display, not
    /// before classifying").
    static func classify(_ result: CommandResult) -> DestinationError {
        if result.didTimeOut { return .timeout }
        let stderr = AzureStderrRedactor.redact(result.stderr)
        if stderr.lowercased().contains(signInHint) {
            return .azNotSignedIn
        }
        return .azFailed(exitCode: result.exitCode)
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

/// Removes access tokens from `az` stderr: JWTs (`eyJ…`, the shape of Entra access and refresh
/// tokens) and GitHub token patterns (GitHubKit's `StderrRedactor`).
enum AzureStderrRedactor {
    private static let jwtPrefix = Array("eyJ")
    /// Characters after `eyJ` before a match counts as a token. Local choice.
    static let minimumTokenBodyLength = 20

    static func redact(_ text: String) -> String {
        StderrRedactor.redactTokenPatterns(in: redactJWTs(in: text))
    }

    private static func redactJWTs(in text: String) -> String {
        let characters = Array(text)
        var output = ""
        output.reserveCapacity(text.utf8.count)
        var index = 0
        while index < characters.count {
            if index + jwtPrefix.count <= characters.count, Array(characters[index..<(index + jwtPrefix.count)]) == jwtPrefix {
                var end = index + jwtPrefix.count
                while end < characters.count, isTokenCharacter(characters[end]) {
                    end += 1
                }
                if end - index - jwtPrefix.count >= minimumTokenBodyLength {
                    output += GHConstants.redactionPlaceholder
                    index = end
                    continue
                }
            }
            output.append(characters[index])
            index += 1
        }
        return output
    }

    private static func isTokenCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
    }
}
