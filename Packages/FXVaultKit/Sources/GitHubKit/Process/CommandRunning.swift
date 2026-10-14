import Foundation
import VaultCore

/// Runs one child process (tasks/todo.md §5.10, §12.2).
///
/// ``ProcessRunner`` is the real implementation; tests and previews use ``FakeCommandRunner``.
/// A timeout is not an error: the result reports it in ``CommandResult/didTimeOut`` so the
/// caller can tell a read timeout from an indeterminate write (§8 E rule 13).
public protocol CommandRunning: Sendable {
    /// Starts `spec`, feeds its stdin, drains stdout and stderr, and returns once the process
    /// has exited (or was terminated after its timeout).
    ///
    /// Throws ``CommandRunnerError/cancelled`` when the calling task is cancelled (the process
    /// is terminated first) and ``CommandRunnerError/launchFailed(errno:)`` when it cannot start.
    func run(_ spec: CommandSpec) async throws(CommandRunnerError) -> CommandResult
}

/// Why a process could not be run to completion.
public enum CommandRunnerError: Error, Sendable, Hashable {
    /// `posix_spawn` (or pipe setup) failed with this `errno`. `ENOENT` means the executable
    /// does not exist.
    case launchFailed(errno: Int32)
    /// The calling task was cancelled; the process was terminated.
    case cancelled
}

/// What a finished process produced.
///
/// `stdout` may hold plaintext (variable values, a token): decode it, then call
/// `stdout.wipe()`. `stderr` is not redacted yet; run ``StderrRedactor`` before displaying or
/// logging it.
public struct CommandResult: Sendable {
    /// The exit status, or `128 + signal` when the process was killed by a signal.
    public let exitCode: Int32
    /// The terminating signal, if the process did not exit normally.
    public let terminationSignal: Int32?
    /// True when the runner terminated the process after ``CommandSpec/timeout``.
    public let didTimeOut: Bool
    /// Captured stdout, at most ``CommandSpec/maxStdoutBytes``.
    public let stdout: SecretBytes
    /// Captured stderr, at most ``CommandSpec/maxStderrBytes``, decoded as UTF-8 (lossy).
    public let stderr: String
    /// True when stdout exceeded its cap and the rest was discarded.
    public let isStdoutTruncated: Bool
    /// True when stderr exceeded its cap and the rest was discarded.
    public let isStderrTruncated: Bool

    public init(
        exitCode: Int32,
        terminationSignal: Int32? = nil,
        didTimeOut: Bool = false,
        stdout: SecretBytes,
        stderr: String,
        isStdoutTruncated: Bool = false,
        isStderrTruncated: Bool = false
    ) {
        self.exitCode = exitCode
        self.terminationSignal = terminationSignal
        self.didTimeOut = didTimeOut
        self.stdout = stdout
        self.stderr = stderr
        self.isStdoutTruncated = isStdoutTruncated
        self.isStderrTruncated = isStderrTruncated
    }

    /// Exit code 0, not timed out.
    public var isSuccess: Bool {
        exitCode == 0 && !didTimeOut && terminationSignal == nil
    }
}
