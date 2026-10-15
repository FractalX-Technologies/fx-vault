import VaultCore

/// What a copy into another scope does with an item whose name that scope already has (v0.4.0).
public enum ItemCopyConflictPolicy: Sendable, Hashable {
    /// Keeps the target scope's item as it is.
    case keep
    /// Replaces the target item's value with the copied value.
    case replace
}

/// The outcome of ``ConfigRepository/copyItems(_:to:repositoryID:conflicts:)``.
public struct ItemCopyResultModel: Sendable, Hashable {
    /// New items in the target scope, pending adds (an item deleted there comes back).
    public var added = 0
    /// Target items whose value the copy replaced.
    public var replaced = 0
    /// Target items kept as they were (``ItemCopyConflictPolicy/keep``).
    public var kept = 0
    /// Secrets that have no value in the vault (GitHub never returns one), by name: not copied.
    public var withoutValue: [String] = []

    public init(added: Int = 0, replaced: Int = 0, kept: Int = 0, withoutValue: [String] = []) {
        self.added = added
        self.replaced = replaced
        self.kept = kept
        self.withoutValue = withoutValue
    }
}
