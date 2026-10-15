import Foundation

/// Constants of the pure sync model (tasks/todo.md §4.7: no magic numbers).
public enum SyncEngineConstants {
    /// Two GitHub timestamps closer than this are the same instant.
    ///
    /// The vault stores timestamps with millisecond precision (DATABASE.md, `DatabaseTimestamp`)
    /// while gh prints Go `time.Time` values with up to nanosecond precision, so an exact `==`
    /// between a listed `updatedAt` and a stored `remote_updated_at` would report drift on every
    /// run (D13). One millisecond is the stored resolution.
    public static let timestampTolerance: TimeInterval = 0.001

    /// Separator of the textual keys written to `sync_journal.target_key`.
    static let journalKeySeparator: Character = "|"
    /// Journal key prefix of the repository itself (repository creation).
    static let journalRepositoryTag = "repo"
    /// Journal key prefix of an environment.
    static let journalEnvironmentTag = "env"
    /// Journal key prefix of a secret or variable.
    static let journalItemTag = "item"
    /// Separator between a change kind and its target in ``ConfigChangeModel/id``.
    static let changeIDSeparator = ":"
}
