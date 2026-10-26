import Foundation
import VaultCore

/// One child process to run (tasks/todo.md §5.10).
///
/// - `executableURL` is absolute; there is never a shell string (except the shell probe, §8 A2,
///   whose script is a constant).
/// - `environment` is the complete environment: nothing is inherited from FX Vault.
/// - `arguments` never contain values; values travel in `stdin`.
///
/// The textual representations hide the environment (it may hold `GH_TOKEN`) and the
/// arguments (they hold repository and item names).
public struct CommandSpec: Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL
    public var stdin: StdinPayload
    public var timeout: Duration
    public var maxStdoutBytes: Int
    public var maxStderrBytes: Int
    /// Sees stderr as it arrives (lossy UTF-8 chunks, unredacted), for a command that prints
    /// what the user needs before it exits (`gh auth refresh`'s device code, 1.0 B4b). Stdout,
    /// which may hold values, is never observed.
    public var stderrObserver: (@Sendable (String) -> Void)?

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: StdinPayload = .empty,
        timeout: Duration,
        maxStdoutBytes: Int = Limits.maxStdoutBytes,
        maxStderrBytes: Int = Limits.maxStderrBytes,
        stderrObserver: (@Sendable (String) -> Void)? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.stdin = stdin
        self.timeout = timeout
        self.maxStdoutBytes = maxStdoutBytes
        self.maxStderrBytes = maxStderrBytes
        self.stderrObserver = stderrObserver
    }
}

extension CommandSpec: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "CommandSpec(\(executableURL.lastPathComponent), \(arguments.count) arguments, \(environment.count) environment keys)"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [], displayStyle: .struct)
    }
}
