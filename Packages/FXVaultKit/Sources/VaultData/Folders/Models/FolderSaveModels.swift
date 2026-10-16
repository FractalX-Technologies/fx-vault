import VaultCore

/// Where a received copy of a folder goes (v0.7.0 "Save as Folder").
public enum FolderSaveTargetModel: Sendable, Hashable {
    /// A new folder with this name (the sender's, or another one the user typed).
    case newFolder(name: String)
    /// One of this vault's folders: names it already has are replaced or kept.
    case existing(FolderID)
}

/// What "Save as Folder" did (names and counts only).
public struct FolderSaveResultModel: Sendable, Hashable {
    public var folderID: FolderID
    /// Added, replaced and kept items (``ItemCopyResultModel/withoutValue`` stays empty: a
    /// folder copy always carries its values).
    public var items: ItemCopyResultModel

    public init(folderID: FolderID, items: ItemCopyResultModel) {
        self.folderID = folderID
        self.items = items
    }
}
