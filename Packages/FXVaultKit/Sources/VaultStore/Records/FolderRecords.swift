import Foundation
import GRDB
import VaultCore

/// One `folders` row (§6 `v12_folders`, v0.7.0).
public struct FolderRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "folders"

    public var id: FolderID
    /// v22: the top-level folder this one is in; nil at the top.
    public var parentID: FolderID?
    /// NFC (``FolderNameValidator``).
    public var name: String
    /// ``FolderNameValidator/foldKey(_:)`` of ``name``; unique per parent.
    public var nameKey: String
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: FolderID = FolderID(), parentID: FolderID? = nil, name: String, sortOrder: Int, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.parentID = parentID
        self.name = name
        nameKey = FolderNameValidator.foldKey(name)
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The domain model with its live item counts.
    public func model(secretCount: Int = 0, variableCount: Int = 0, fileCount: Int = 0) -> FolderModel {
        FolderModel(
            id: id,
            parentID: parentID,
            name: name,
            sortOrder: sortOrder,
            secretCount: secretCount,
            variableCount: variableCount,
            fileCount: fileCount,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case parentID = "parent_id"
        case name
        case nameKey = "name_key"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        DatabaseTimestamp.encodingStrategy
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        DatabaseTimestamp.decodingStrategy
    }
}

/// One `folder_items` row (§6 `v12_folders`, v0.7.0), ciphertext included. The value is sealed
/// with `FolderFieldAAD` (row, folder, kind, name) and fingerprinted for its row, like a
/// repository item's local value.
public struct FolderItemRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "folder_items"

    public var id: ConfigItemID
    public var folderID: FolderID
    public var kind: ConfigKind
    /// Uppercase (`CHECK (name = upper(name))`).
    public var name: String
    /// `value_ct`, never nil: a folder item always has its value.
    public var valueCiphertext: Data
    /// `value_fp`: the row-bound HMAC fingerprint of the value.
    public var valueFingerprint: Data
    public var linkID: ItemLinkID?
    /// `file_detail` (v21): the file the value came from, as JSON; nil for a typed value.
    public var file: FileSecretModel?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ConfigItemID = ConfigItemID(),
        folderID: FolderID,
        kind: ConfigKind,
        name: String,
        valueCiphertext: Data,
        valueFingerprint: Data,
        linkID: ItemLinkID? = nil,
        file: FileSecretModel? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.folderID = folderID
        self.kind = kind
        self.name = name
        self.valueCiphertext = valueCiphertext
        self.valueFingerprint = valueFingerprint
        self.linkID = linkID
        self.file = file
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The domain model (no ciphertext), with the link group's live count.
    public func model(linkCount: Int = 0) -> FolderItemModel {
        FolderItemModel(
            id: id,
            folderID: folderID,
            kind: kind,
            name: name,
            linkID: linkID,
            linkCount: linkCount,
            file: file,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case folderID = "folder_id"
        case kind
        case name
        case valueCiphertext = "value_ct"
        case valueFingerprint = "value_fp"
        case linkID = "link_id"
        case file = "file_detail"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        DatabaseTimestamp.encodingStrategy
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        DatabaseTimestamp.decodingStrategy
    }
}

/// One `folder_files` row (v23): a file's metadata, never its bytes (``FolderFileBlobRecord``).
public struct FolderFileRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "folder_files"

    public var id: FolderFileID
    public var folderID: FolderID
    /// NFC (``FolderFileNameValidator``).
    public var name: String
    /// ``FolderNameValidator/foldKey(_:)`` of ``name``; unique per folder.
    public var nameKey: String
    public var byteCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: FolderFileID = FolderFileID(), folderID: FolderID, name: String, byteCount: Int, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.folderID = folderID
        self.name = name
        nameKey = FolderNameValidator.foldKey(name)
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var model: FolderFileModel {
        FolderFileModel(id: id, folderID: folderID, name: name, byteCount: byteCount, createdAt: createdAt, updatedAt: updatedAt)
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case folderID = "folder_id"
        case name
        case nameKey = "name_key"
        case byteCount = "byte_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        DatabaseTimestamp.encodingStrategy
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        DatabaseTimestamp.decodingStrategy
    }
}

/// One `folder_file_blobs` row (v23): a file's bytes sealed with `FolderFileAAD`.
public struct FolderFileBlobRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "folder_file_blobs"

    public var fileID: FolderFileID
    public var contentCiphertext: Data

    public init(fileID: FolderFileID, contentCiphertext: Data) {
        self.fileID = fileID
        self.contentCiphertext = contentCiphertext
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case fileID = "file_id"
        case contentCiphertext = "content_ct"
    }
}
