import VaultCore

/// The outcome of an item write that took a value or a name.
public struct ItemWriteResultModel: Sendable, Hashable {
    /// The row that now holds the item. Differs from the edited row when the edit revived a
    /// tombstone (§7.1: adding, renaming or moving into a deleted name) or moved the item.
    public let itemID: ConfigItemID
    /// True when trailing CR/LF was stripped from the value (D32): the editor shows a notice.
    public let didStripTrailingNewlines: Bool

    public init(itemID: ConfigItemID, didStripTrailingNewlines: Bool) {
        self.itemID = itemID
        self.didStripTrailingNewlines = didStripTrailingNewlines
    }
}

/// What a local environment rename means on GitHub (§7.1, §7.6, D20).
public enum EnvironmentRenameKind: Sendable, Hashable {
    /// Nothing changed (same name).
    case unchanged
    /// The environment was never synced, or the name went back to the synced one: local only.
    case local
    /// Only the case changed: local only, GitHub keeps its stored case (the UI notes this).
    case caseOnly
    /// A synced environment got a new name: the next Sync recreates it on GitHub (guided rename,
    /// §7.6), blocked while any of its secrets is value-missing.
    case recreateOnGitHub
}
