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

/// Where a linked copy is (v0.7.0): a scope of a vault repository, or a folder.
public enum LinkedCopyPlaceModel: Sendable, Hashable {
    case scope(
        repositoryID: RepoID,
        accountLogin: String,
        repositoryFullName: String,
        scope: ConfigScope,
        environmentName: String?
    )
    case folder(FolderID, name: String)
}

/// Another place of a linked item (v0.4.1; folders since v0.7.0): one row of the Linked chip's
/// popover and of the "Also update linked copies" list.
public struct LinkedCopyModel: Sendable, Hashable, Identifiable {
    public var itemID: ConfigItemID
    public var place: LinkedCopyPlaceModel
    public var kind: ConfigKind
    public var name: String
    public var comparison: LinkedValueComparison
    /// The copy's sync status; nil for a folder item (a folder never syncs).
    public var syncStatus: ConfigSyncStatus?
    /// Why this copy cannot be changed (`.readOnly`, `.environmentDeleted`), or nil.
    public var editBlock: ConfigRepositoryError?

    public init(
        itemID: ConfigItemID,
        place: LinkedCopyPlaceModel,
        kind: ConfigKind,
        name: String,
        comparison: LinkedValueComparison,
        syncStatus: ConfigSyncStatus?,
        editBlock: ConfigRepositoryError?
    ) {
        self.itemID = itemID
        self.place = place
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

    /// `owner/name`, or the folder's name.
    public var placeName: String {
        switch place {
        case .scope(_, _, let fullName, _, _): fullName
        case .folder(_, let name): name
        }
    }

    /// The place to open.
    public var itemPlace: ItemPlaceModel {
        switch place {
        case .scope(let repositoryID, _, _, let scope, _): .scope(repositoryID: repositoryID, scope: scope)
        case .folder(let id, _): .folder(id)
        }
    }
}
