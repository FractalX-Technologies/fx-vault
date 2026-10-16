import VaultCore

/// A scope an item can move to (Convert/Move, D11).
struct ItemScopeOptionModel: Identifiable, Hashable {
    let scope: ConfigScope
    let title: String
    /// False where the viewer cannot change items (environments need admin, §2 Permissions).
    let isEditable: Bool

    var id: String {
        scope.environmentID?.uuidString ?? ConfigScopeLevel.repository.rawValue
    }
}

/// A confirmation the editor asks before a risky save (secret → variable, §5.13). The confirm
/// button is destructive, so Cancel is the default (Return) button.
struct ItemEditorConfirmationModel: Hashable {
    let title: String
    let message: String
    let confirmTitle: String
}

/// The credential-looking-variable warning (§5.13): the reasons, never the value, plus what the
/// editor can do about it.
struct CredentialWarningModel: Hashable {
    enum Action: Hashable {
        /// The kind can still change: switch the picker to Secret.
        case switchToSecret
        /// The variable is on GitHub (kind locked, D11): open Convert or Move.
        case convertToSecret
    }

    let reasons: [String]
    let action: Action?
}

/// The item the editor works on (v0.7.0): a repository item or a folder item, with the facts the
/// form needs. A folder item is never on GitHub, so its kind stays editable and nothing is pending.
struct EditorItemModel: Hashable, Identifiable {
    let id: ConfigItemID
    let kind: ConfigKind
    let name: String
    let hasValue: Bool
    let isDeleted: Bool
    let isLinked: Bool
    let isSynced: Bool
    let syncedName: String?
    /// Nil for a folder item.
    let syncStatus: ConfigSyncStatus?
    /// The repository scope; nil for a folder item.
    let scope: ConfigScope?

    init(_ item: ConfigItemModel) {
        id = item.id
        kind = item.kind
        name = item.name
        hasValue = item.hasValue
        isDeleted = item.isDeleted
        isLinked = item.isLinked
        isSynced = item.isSynced
        syncedName = item.syncedName
        syncStatus = item.syncStatus
        scope = item.scope
    }

    init(_ item: FolderItemModel) {
        id = item.id
        kind = item.kind
        name = item.name
        hasValue = true
        isDeleted = false
        isLinked = item.isLinked
        isSynced = false
        syncedName = nil
        syncStatus = nil
        scope = nil
    }

    /// A destination item (v0.8.0): pending until the next Sync, like a repository item; its kind
    /// changes in place where the provider stores variables.
    init(_ item: DestinationItemModel) {
        id = item.id
        kind = item.kind
        name = item.name
        hasValue = item.hasValue
        isDeleted = item.isDeleted
        isLinked = item.isLinked
        isSynced = item.isSynced
        syncedName = item.syncedName
        syncStatus = item.syncStatus
        scope = nil
        isDestinationItem = true
    }

    /// True for a destination item, whose kind is not locked by a sync.
    private(set) var isDestinationItem = false

    /// Kind and scope can no longer change (D11): only for an item on GitHub.
    var isKindAndScopeLocked: Bool {
        isSynced && !isDestinationItem
    }

    /// `name` case-folded.
    var nameKey: String {
        GitHubNameValidator.foldKey(name)
    }
}
