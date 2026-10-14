import Foundation
import os

/// Fixed strings and protocol constants of the gh layer (tasks/todo.md §5.10, §8, D6).
///
/// Numeric limits and durations live in VaultCore's `Limits` and `Timeouts`; this enum holds
/// what only GitHubKit needs.
public enum GHConstants {
    /// The only GitHub host FX Vault talks to (D29).
    public static let host = "github.com"
    /// `X-GitHub-Api-Version`, sent only on `gh api` calls (D6).
    public static let apiVersion = "2026-03-10"
    /// `Accept` header for `gh api` calls.
    public static let acceptHeader = "application/vnd.github+json"
    /// `per_page` for paginated `gh api` reads (GitHub's maximum).
    public static let apiPerPage = 100
    /// `LANG` passed to gh, git and ssh so their stderr stays English for the classifier.
    public static let processLanguage = "en_US.UTF-8"
    /// The PATH used when no login-shell PATH was captured.
    public static let defaultPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    /// The PATH given to the shell probe itself (system directories only).
    public static let systemPATH = "/usr/bin:/bin:/usr/sbin:/sbin"
    /// Absolute path of git (§5.10).
    public static let gitPath = "/usr/bin/git"
    /// Absolute path of ssh (§5.10).
    public static let sshPath = "/usr/bin/ssh"
    /// Longest message kept from stderr in ``GHError/validation(_:)``.
    public static let maxErrorMessageLength = 500
    /// Logging subsystem (§4.5).
    public static let logSubsystem = "io.fractalx.fxvault"
    /// The placeholder that replaces redacted text.
    public static let redactionPlaceholder = "<redacted>"
}

/// The gh layer's loggers (§4.5). Never log values, tokens, stdin, environments or bodies.
enum GHLog {
    /// gh, git and ssh invocations: command templates, exit codes and classified errors.
    static let gh = Logger(subsystem: GHConstants.logSubsystem, category: "gh")
}
