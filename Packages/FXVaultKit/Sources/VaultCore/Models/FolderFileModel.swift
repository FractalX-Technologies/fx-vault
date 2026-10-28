import Foundation

/// A file kept in a folder (v23, `folder_files` row): any file up to ``Limits/maxFolderFileBytes``,
/// sealed in the vault and saved back to disk only after re-authentication. The name and size are
/// plaintext metadata, like a folder's name; the bytes never leave the vault unsealed otherwise.
public struct FolderFileModel: Sendable, Hashable, Identifiable {
    public var id: FolderFileID
    public var folderID: FolderID
    /// NFC, 1–``Limits/maxFolderFileNameLength`` scalars, unique by fold key in its folder.
    public var name: String
    public var byteCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: FolderFileID = FolderFileID(), folderID: FolderID, name: String, byteCount: Int, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.folderID = folderID
        self.name = name
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
