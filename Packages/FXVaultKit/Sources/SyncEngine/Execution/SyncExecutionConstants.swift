import Foundation

/// Constants of sync execution (tasks/todo.md §4.7: no magic numbers). Durations and counts
/// shared with other modules live in VaultCore's `Timeouts` and `Limits`.
public enum SyncExecutionConstants {
    /// gh's success exit code, written to `sync_journal.exit_code`.
    public static let successExitCode = 0
    /// `sync_journal.scope_label` of repository-level rows (environment rows use the remote
    /// environment name). Data, not user-facing text.
    public static let repositoryScopeLabel = "repository"
    /// `sync_journal.error_code` of a change the per-scope re-list blocked (D27).
    public static let remoteChangedErrorCode = "remoteChanged"
    /// `sync_journal.error_code` of a create that could not be adopted (§7.3).
    public static let createConflictErrorCode = "createConflict"
    /// `sync_journal.error_code` of an outcome that a re-list did not confirm.
    public static let notConfirmedErrorCode = "notConfirmed"
    /// `sync_journal.error_code` of a rename whose new environment has the old one's id.
    public static let renameTargetIsSourceErrorCode = "renameTargetIsSource"
}
