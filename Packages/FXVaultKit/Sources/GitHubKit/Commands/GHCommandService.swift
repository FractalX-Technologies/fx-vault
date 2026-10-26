import Darwin
import Foundation
import os
import VaultCore

/// The result of a successful gh call (exit code 0).
///
/// `stdout` may hold plaintext (variable values, a token). The decoders on the builder enums
/// (`GHSecretsCommands.decodeList(_:)`, ...) wipe it; callers reading it directly call
/// ``wipe()``.
public struct GHCommandOutput: Sendable {
    public let operation: GHOperation
    /// stdout. Empty for `gh api -i` calls, whose output is in ``response``.
    public let stdout: SecretBytes
    /// Redacted stderr (gh may print notices on success).
    public let stderr: String
    /// The parsed `gh api -i` response (B4, C2–C4, C9).
    public let response: APIResponseModel?

    public init(operation: GHOperation, stdout: SecretBytes, stderr: String = "", response: APIResponseModel? = nil) {
        self.operation = operation
        self.stdout = stdout
        self.stderr = stderr
        self.response = response
    }

    /// Wipes stdout.
    public func wipe() {
        stdout.wipe()
    }
}

/// Runs one ``GHCommand`` through ``CommandRunning`` with the §5.10 environment
/// (tasks/todo.md §8 conventions, D7). One attempt, no retries: ``GHCommandScheduler`` adds
/// serialization, throttling and retries.
///
/// - Success is exit code 0; stdout is parsed only then.
/// - Failures are classified from stderr (token patterns removed), the exit code and, for
///   `gh api -i`, the status line (``GHStderrClassifier``). Text that is kept or shown (the
///   ``GHError/validation(_:)`` message) is fully redacted, including the value and token.
/// - Logs the command template, exit code and classified error; never argv, stdin,
///   environment or output (§4.5).
public struct GHCommandService: Sendable {
    public let executableURL: URL
    private let identity: ProcessIdentityModel
    private let shell: ShellEnvironmentModel
    private let workingDirectory: URL
    private let runner: any CommandRunning

    public init(
        executableURL: URL,
        identity: ProcessIdentityModel,
        shell: ShellEnvironmentModel,
        workingDirectory: URL,
        runner: any CommandRunning
    ) {
        self.executableURL = executableURL
        self.identity = identity
        self.shell = shell
        self.workingDirectory = workingDirectory
        self.runner = runner
    }

    /// A service for the gh binary `GHLocator` resolved.
    public init(
        installation: GHInstallationModel,
        identity: ProcessIdentityModel,
        shell: ShellEnvironmentModel,
        workingDirectory: URL,
        runner: any CommandRunning
    ) {
        self.init(
            executableURL: URL(fileURLWithPath: installation.path),
            identity: identity,
            shell: shell,
            workingDirectory: workingDirectory,
            runner: runner
        )
    }

    /// Runs `command` once. `token` is the account's token for operations that need one
    /// (ignored otherwise); it is not wiped here. The command's stdin value is copied into a
    /// payload the runner wipes; the command itself is not wiped.
    /// `stderrObserver` sees stderr while gh runs (A7's device code); see ``CommandSpec``.
    public func execute(
        _ command: GHCommand,
        token: SecretBytes?,
        stderrObserver: (@Sendable (String) -> Void)? = nil
    ) async throws(GHError) -> GHCommandOutput {
        let operation = command.operation
        let effectiveToken = operation.requiresToken ? token : nil
        if operation.requiresToken && effectiveToken == nil {
            throw .notAuthenticated
        }
        let environment = try ProcessEnvironmentBuilder.gh(identity: identity, shell: shell, token: effectiveToken)
        let spec = CommandSpec(
            executableURL: executableURL,
            arguments: command.arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            stdin: command.makeStdinPayload(),
            timeout: operation.timeout,
            stderrObserver: stderrObserver
        )

        let result: CommandResult
        do {
            result = try await runner.run(spec)
        } catch {
            let mapped = map(error)
            GHLog.gh.error(
                "gh \(command.logTemplate, privacy: .public) did not run: \(mapped.logCode, privacy: .public)"
            )
            throw mapped
        }

        let secrets = [command.stdinValue, effectiveToken].compactMap { $0 }
        let stderr = StderrRedactor.redact(result.stderr, secrets: secrets)

        if result.isSuccess {
            return try success(command: command, result: result, stderr: stderr)
        }

        // `gh api -i` (environments and branch policies, never values): the status line, and the
        // body's `errors[]` details, which gh does not print on stderr (§8 E).
        var responseStatus: Int?
        var responseDetails: [String] = []
        if operation.includesResponseHead {
            var data = result.stdout.withUnsafeBytes { Data($0) }
            responseStatus = APIResponseParser.statusIfPresent(in: data)
            responseDetails = APIResponseParser.errorDetails(in: data)
            data.secureWipe()
        }
        if let responseStatus, operation.acceptedNonZeroExitStatuses.contains(responseStatus), !result.didTimeOut {
            // C3: a bare 303 (gh exits 1 with `gh: HTTP 303`) counts as success (§8 C3).
            return try success(command: command, result: result, stderr: stderr)
        }
        result.stdout.wipe()
        // Classify on stderr with only token patterns removed: replacing a short plaintext value
        // (say "v") would corrupt the fragments the rules match ("Must ha<redacted>e admin").
        // Anything shown or kept (the validation message) comes from the fully redacted text.
        var error = GHStderrClassifier.classify(GHFailureContext(
            operation: operation,
            exitCode: result.exitCode,
            stderr: StderrRedactor.redactTokenPatterns(in: result.stderr),
            responseStatus: responseStatus,
            didTimeOut: result.didTimeOut,
            responseDetails: responseDetails.map(StderrRedactor.redactTokenPatterns(in:))
        ))
        if case .validation = error {
            let details = responseDetails.map { StderrRedactor.redact($0, secrets: secrets) }
            error = .validation(GHStderrClassifier.message(from: stderr, details: details))
        }
        GHLog.gh.error(
            "gh \(command.logTemplate, privacy: .public) exit=\(result.exitCode, privacy: .public) timedOut=\(result.didTimeOut, privacy: .public) error=\(error.logCode, privacy: .public)"
        )
        throw error
    }

    private func success(command: GHCommand, result: CommandResult, stderr: String) throws(GHError)
        -> GHCommandOutput
    {
        GHLog.gh.info("gh \(command.logTemplate, privacy: .public) exit=\(result.exitCode, privacy: .public)")
        if result.isStdoutTruncated {
            result.stdout.wipe()
            throw .outputTooLarge
        }
        guard command.operation.includesResponseHead else {
            return GHCommandOutput(operation: command.operation, stdout: result.stdout, stderr: stderr)
        }
        var data = result.stdout.withUnsafeBytes { Data($0) }
        defer { data.secureWipe() }
        result.stdout.wipe()
        let response = try APIResponseParser.parse(data)
        return GHCommandOutput(
            operation: command.operation,
            stdout: SecretBytes(count: 0),
            stderr: stderr,
            response: response
        )
    }

    /// `posix_spawn` reports ENOENT both for a missing executable and a missing working
    /// directory; only the former means gh is not installed.
    private func map(_ error: CommandRunnerError) -> GHError {
        switch error {
        case .cancelled:
            return .cancelled
        case .launchFailed(let code) where code == ENOENT:
            return FileManager.default.fileExists(atPath: executableURL.path) ? .launchFailed : .notInstalled
        case .launchFailed:
            return .launchFailed
        }
    }
}
