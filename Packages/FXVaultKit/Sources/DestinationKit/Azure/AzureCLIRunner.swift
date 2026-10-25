import Darwin
import Foundation
import GitHubKit
import VaultCore

/// Runs one read-only `az` command: a trusted `az` (``AzureCLILocator``, checked before every
/// run), argv only, empty stdin, the empty working directory and an exact environment. The token
/// provider and ``AzureCLIDiscovery`` both go through it, so these rules live in one place.
public struct AzureCLIRunner: Sendable {
    /// The `exitCode` of ``DestinationError/azFailed(exitCode:)`` when `az` could not start.
    public static let launchFailedExitCode: Int32 = -1

    /// Ends every argv: FX Vault reads only `az`'s JSON output.
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
    /// ARM's code when the signed-in account has no role on the scope (`az keyvault list`).
    private static let authorizationFailedCode = "authorizationfailed"

    private let runner: any CommandRunning
    private let locator: AzureCLILocator
    private let overridePath: String?
    private let identity: ProcessIdentityModel
    private let shell: ShellEnvironmentModel
    private let workingDirectory: URL
    private let azureConfigDirectory: String?

    /// `overridePath` is then the only candidate; `shell`'s PATH is searched and passed to `az`;
    /// `azureConfigDirectory` nil keeps `az`'s default.
    public init(
        runner: any CommandRunning,
        locator: AzureCLILocator = AzureCLILocator(),
        overridePath: String? = nil,
        identity: ProcessIdentityModel,
        shell: ShellEnvironmentModel,
        workingDirectory: URL,
        azureConfigDirectory: String? = nil
    ) {
        self.runner = runner
        self.locator = locator
        self.overridePath = overridePath
        self.identity = identity
        self.shell = shell
        self.workingDirectory = workingDirectory
        self.azureConfigDirectory = azureConfigDirectory
    }

    /// Runs `<az> <arguments>` and returns stdout, which the caller wipes. A truncated stdout is
    /// ``DestinationError/responseTooLarge``: a cut JSON document is never read.
    func run(_ arguments: [String], timeout: Duration) async throws(DestinationError) -> SecretBytes {
        let installation = try locator.locate(overridePath: overridePath, shell: shell, home: identity.home)
        let spec = CommandSpec(
            executableURL: URL(fileURLWithPath: installation.resolvedPath),
            arguments: arguments,
            environment: Self.environment(identity: identity, shell: shell, azureConfigDirectory: azureConfigDirectory),
            workingDirectory: workingDirectory,
            stdin: .empty,
            timeout: timeout
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
        guard result.isSuccess else {
            result.stdout.wipe()
            throw Self.classify(result)
        }
        guard !result.isStdoutTruncated else {
            result.stdout.wipe()
            throw .responseTooLarge
        }
        return result.stdout
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

    /// Classifies a failed run, reading stderr only after token patterns are redacted
    /// (tasks/lessons.md, "Redact for display, not before classifying"): timeout, "az login",
    /// ARM's `AuthorizationFailed` (→ ``DestinationError/forbidden``), else the exit code.
    static func classify(_ result: CommandResult) -> DestinationError {
        if result.didTimeOut { return .timeout }
        let stderr = AzureStderrRedactor.redact(result.stderr).lowercased()
        if stderr.contains(signInHint) {
            return .azNotSignedIn
        }
        if stderr.contains(authorizationFailedCode) {
            return .forbidden
        }
        return .azFailed(exitCode: result.exitCode)
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
