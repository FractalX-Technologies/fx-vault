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

    /// How close to a push request (`force_push_requested_at`) a GitHub secret change may be and
    /// still count as made after it, so it blocks the push (D27).
    ///
    /// GitHub lists a secret's `updatedAt` in whole seconds while the request time is the Mac's
    /// clock with sub-second precision, and the two clocks can disagree by a few seconds. A
    /// change counts as covered by the request only when its `updatedAt` is earlier than the
    /// request's whole second minus this margin; an unclear order blocks, and the drift review
    /// resolves it.
    public static let requestedPushClockMargin: TimeInterval = 5

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
