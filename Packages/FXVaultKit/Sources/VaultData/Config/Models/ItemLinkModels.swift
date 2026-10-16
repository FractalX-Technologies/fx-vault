import VaultCore

/// How a linked copy's value compares with the item it is listed for (v0.4.1).
public enum LinkedValueComparison: Sendable, Hashable {
    /// Both have a value and the values are equal.
    case same
    /// Both have a value and the values differ.
    case differs
    /// This copy is a secret without a value in the vault.
    case valueMissing
    /// The item it is listed for has no value, so nothing can be compared.
    case unknown
}

/// Another place of a linked item (v0.4.1): one row of the Linked chip's popover and of the
/// "Also update linked copies" list.
public struct LinkedCopyModel: Sendable, Hashable, Identifiable {
    public var itemID: ConfigItemID
    public var repositoryID: RepoID
    /// The gh account the repository belongs to.
    public var accountLogin: String
    /// `owner/name`.
    public var repositoryFullName: String
    public var scope: ConfigScope
    /// The environment's name; nil at repository level.
    public var environmentName: String?
    public var kind: ConfigKind
    public var name: String
    public var comparison: LinkedValueComparison
    public var syncStatus: ConfigSyncStatus
    /// Why this copy cannot be changed (`.readOnly`, `.environmentDeleted`), or nil.
    public var editBlock: ConfigRepositoryError?

    public init(
        itemID: ConfigItemID,
        repositoryID: RepoID,
        accountLogin: String,
        repositoryFullName: String,
        scope: ConfigScope,
        environmentName: String?,
        kind: ConfigKind,
        name: String,
        comparison: LinkedValueComparison,
        syncStatus: ConfigSyncStatus,
        editBlock: ConfigRepositoryError?
    ) {
        self.itemID = itemID
        self.repositoryID = repositoryID
        self.accountLogin = accountLogin
        self.repositoryFullName = repositoryFullName
        self.scope = scope
        self.environmentName = environmentName
        self.kind = kind
        self.name = name
        self.comparison = comparison
        self.syncStatus = syncStatus
        self.editBlock = editBlock
    }

    public var id: ConfigItemID {
        itemID
    }

    /// True when this copy can take a new value.
    public var isEditable: Bool {
        editBlock == nil
    }
}
