import Foundation
import VaultCore
import VaultCrypto
import VaultStore

/// The source of a copy or a link lookup (v0.7.0): a repository item (`config_items`), a folder
/// item (`folder_items`) or (v0.8.0) a destination item (`destination_items`). Their ids never
/// collide, so one id names one row of one table.
struct ItemCopySource {
    let id: ConfigItemID
    let kind: ConfigKind
    let name: String
    let linkID: ItemLinkID?
    let place: ItemPlaceModel
    /// A repository or destination tombstone (folder items are never deleted in place).
    let isDeleted: Bool
    private let row: Row

    private enum Row {
        case config(ConfigItemRecord)
        case folder(FolderItemRecord)
        case destination(DestinationItemRecord)
    }

    init(_ record: ConfigItemRecord) {
        id = record.id
        kind = record.kind
        name = record.name
        linkID = record.linkID
        place = .scope(repositoryID: record.repositoryID, scope: record.scope)
        isDeleted = record.isDeleted
        row = .config(record)
    }

    init(_ record: FolderItemRecord) {
        id = record.id
        kind = record.kind
        name = record.name
        linkID = record.linkID
        place = .folder(record.folderID)
        isDeleted = false
        row = .folder(record)
    }

    init(_ record: DestinationItemRecord) {
        id = record.id
        kind = record.kind
        name = record.name
        linkID = record.linkID
        place = .destination(record.destinationID)
        isDeleted = record.isDeleted
        row = .destination(record)
    }

    /// The row with `id` in any of the three tables, or nil.
    static func load(_ id: ConfigItemID, database: VaultDatabase, in tx: StoreTransaction) throws -> ItemCopySource? {
        if let record = try ConfigStore(database: database).fetchItemRecord(id: id, in: tx) {
            return ItemCopySource(record)
        }
        if let record = try FolderStore(database: database).fetchItemRecord(id: id, in: tx) {
            return ItemCopySource(record)
        }
        return try DestinationStore(database: database).fetchItemRecord(id: id, in: tx).map(ItemCopySource.init)
    }

    /// The row with `id` in either table, read in its own transaction.
    static func load(_ id: ConfigItemID, database: VaultDatabase) throws -> ItemCopySource? {
        try database.read { try load(id, database: database, in: $0) }
    }

    /// The decrypted value, or nil for a value-missing repository or destination secret. The
    /// caller wipes it.
    func openValue(keys: borrowing UnlockedKeys) throws(VaultError) -> SecretBytes? {
        switch row {
        case .config(let record): try ConfigFieldCipher.openValue(of: record, keys: keys)
        case .folder(let record): try FolderFieldCipher.openValue(of: record, keys: keys)
        case .destination(let record): try DestinationFieldCipher.openValue(of: record, keys: keys)
        }
    }

    /// True when the row is already in `place` (nothing to copy).
    func isIn(_ place: ItemPlaceModel) -> Bool {
        self.place == place
    }

    /// Every live member of `linkID`'s group, in repositories and destinations (no tombstones)
    /// and folders.
    static func linkGroup(_ linkID: ItemLinkID, database: VaultDatabase, in tx: StoreTransaction) throws -> [ItemCopySource] {
        let repositoryItems = try ConfigStore(database: database).fetchLinkedItemRecords(linkID: linkID, in: tx)
        let folderItems = try FolderStore(database: database).fetchLinkedItemRecords(linkID: linkID, in: tx)
        let destinationItems = try DestinationStore(database: database).fetchLinkedItemRecords(linkID: linkID, in: tx)
        return repositoryItems.map(ItemCopySource.init) + folderItems.map(ItemCopySource.init)
            + destinationItems.map(ItemCopySource.init)
    }

    /// Sets `link_id` on `itemIDs`, whichever table each one is in (link metadata only).
    static func setLinkID(_ linkID: ItemLinkID?, itemIDs: [ConfigItemID], database: VaultDatabase, in tx: StoreTransaction) throws {
        try ConfigStore(database: database).setLinkID(linkID, itemIDs: itemIDs, in: tx)
        try FolderStore(database: database).setLinkID(linkID, itemIDs: itemIDs, in: tx)
        try DestinationStore(database: database).setLinkID(linkID, itemIDs: itemIDs, in: tx)
    }

    /// Links a copy to this source: both share the source's group, or a new one when the source
    /// had none.
    func link(copy copyID: ConfigItemID, database: VaultDatabase, in tx: StoreTransaction) throws {
        let link = linkID ?? ItemLinkID()
        try Self.setLinkID(link, itemIDs: linkID == nil ? [id, copyID] : [copyID], database: database, in: tx)
    }

    /// The file the value came from (v21): copies and linked updates carry it with the value.
    var file: FileSecretModel? {
        switch row {
        case .config(let record): record.file
        case .folder(let record): record.file
        case .destination(let record): record.file
        }
    }

    /// The repository record, for callers that need repository-only facts; nil for a folder item.
    var configRecord: ConfigItemRecord? {
        if case .config(let record) = row { return record }
        return nil
    }

    /// The folder record; nil for any other item.
    var folderRecord: FolderItemRecord? {
        if case .folder(let record) = row { return record }
        return nil
    }

    /// The destination record; nil for any other item.
    var destinationRecord: DestinationItemRecord? {
        if case .destination(let record) = row { return record }
        return nil
    }
}
