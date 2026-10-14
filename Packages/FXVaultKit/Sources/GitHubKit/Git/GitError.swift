import Foundation
import VaultCore

/// Failures of git and ssh calls (tasks/todo.md §8 D). Carries no localized text.
public enum GitError: Error, Sendable, Hashable {
    /// The SSH alias does not match `^[A-Za-z0-9][A-Za-z0-9._-]*$`.
    case invalidAlias
    /// A path argument failed validation (D29).
    case invalidPath(ValidationError)
    /// The clone destination would be outside the chosen folder.
    case destinationOutsideFolder
    /// `<folder>/<name>` already exists.
    case destinationExists
    /// macOS refused access to the folder (EPERM): Files and Folders permission guidance.
    case folderAccessDenied
    /// ssh `Permission denied` or `Repository not found`: the alias's key cannot read the
    /// repository (show alias guidance and the D2 result).
    case authenticationFailed
    /// `Host key verification failed`: the user must run `ssh -T git@<alias>` once in Terminal.
    /// Host-key checking is never weakened.
    case hostKeyVerificationFailed
    /// The alias does not resolve to `github.com` (D1).
    case aliasNotGitHub(hostName: String)
    /// The process ran past its timeout and was terminated.
    case timeout
    /// git or ssh exited with this code for another reason.
    case commandFailed(exitCode: Int32)
    /// Output could not be parsed.
    case malformedOutput
    /// The process could not be started.
    case launchFailed
    /// The calling task was cancelled.
    case cancelled

    /// A stable, value-free identifier for logs.
    public var logCode: String {
        switch self {
        case .invalidAlias: "invalidAlias"
        case .invalidPath: "invalidPath"
        case .destinationOutsideFolder: "destinationOutsideFolder"
        case .destinationExists: "destinationExists"
        case .folderAccessDenied: "folderAccessDenied"
        case .authenticationFailed: "authenticationFailed"
        case .hostKeyVerificationFailed: "hostKeyVerificationFailed"
        case .aliasNotGitHub: "aliasNotGitHub"
        case .timeout: "timeout"
        case .commandFailed(let exitCode): "commandFailed(\(exitCode))"
        case .malformedOutput: "malformedOutput"
        case .launchFailed: "launchFailed"
        case .cancelled: "cancelled"
        }
    }

    static func map(_ error: CommandRunnerError) -> GitError {
        switch error {
        case .cancelled: .cancelled
        case .launchFailed: .launchFailed
        }
    }
}
