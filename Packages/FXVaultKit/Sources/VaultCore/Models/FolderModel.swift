import Foundation

/// A folder of secrets and variables (v0.7.0, `folders` row): a named collection that belongs to
/// no repository or account and is never pushed by itself. Repositories get its items by copy
/// and paste; teammates by a copy sent in a `.fxvault` file.
public struct FolderModel: Sendable, Hashable, Identifiable {
    public var id: FolderID
    /// NFC, 1–``Limits/maxFolderNameLength`` scalars (``FolderNameValidator``), unique by fold key.
    public var name: String
    /// The sidebar order (ascending).
    public var sortOrder: Int
    /// Live secrets and variables, set by the folder observation.
    public var secretCount: Int
    public var variableCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: FolderID = FolderID(),
        name: String,
        sortOrder: Int,
        secretCount: Int = 0,
        variableCount: Int = 0,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.secretCount = secretCount
        self.variableCount = variableCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Secrets and variables together.
    public var itemCount: Int {
        secretCount + variableCount
    }

    /// `name` case-folded (``FolderNameValidator/foldKey(_:)``).
    public var nameKey: String {
        FolderNameValidator.foldKey(name)
    }
}

/// A secret or variable in a folder (v0.7.0, `folder_items` row), without its value.
///
/// Its id is a ``ConfigItemID``: copy and paste, linked copies and the detail table treat a
/// folder item and a repository item alike, and the two tables never share an id. A folder item
/// always has a value (nothing in a folder comes from GitHub).
public struct FolderItemModel: Sendable, Hashable, Identifiable {
    public var id: ConfigItemID
    public var folderID: FolderID
    public var kind: ConfigKind
    /// Uppercase (``GitHubNameValidator``), so it can be pasted into any repository.
    public var name: String
    /// The group of linked copies this item belongs to, or nil. Groups span folders and
    /// repositories.
    public var linkID: ItemLinkID?
    /// How many live items (this one included) share ``linkID`` in folders and repositories, set
    /// by the item observation; 0 when not linked.
    public var linkCount: Int
    /// Set when the value came from a file (1.0 F1): its name, lines and encoding, never content.
    public var file: FileSecretModel?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ConfigItemID = ConfigItemID(),
        folderID: FolderID,
        kind: ConfigKind,
        name: String,
        linkID: ItemLinkID? = nil,
        linkCount: Int = 0,
        file: FileSecretModel? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.folderID = folderID
        self.kind = kind
        self.name = name
        self.linkID = linkID
        self.linkCount = linkCount
        self.file = file
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// True when at least one other live item shares this item's link.
    public var isLinked: Bool {
        linkID != nil && linkCount > 1
    }

    /// `name` case-folded; names compare case-insensitively, as on GitHub.
    public var nameKey: String {
        GitHubNameValidator.foldKey(name)
    }
}
