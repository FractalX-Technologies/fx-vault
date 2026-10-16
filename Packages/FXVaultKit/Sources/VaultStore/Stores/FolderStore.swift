import Foundation
import GRDB
import VaultCore

/// `folders` and `folder_items` (§6 `v12_folders`, v0.7.0).
///
/// No sync path reads these tables: folder items reach a repository only as copies written by
/// VaultData into `config_items`. Link groups (`link_id`) span both tables, so the link counts
/// here and in ``ConfigStore`` count the rows of both.
public struct FolderStore: Sendable {
    public let database: VaultDatabase

    public init(database: VaultDatabase) {
        self.database = database
    }

    // MARK: - Folders

    public func fetchFolder(id: FolderID) throws -> FolderRecord? {
        try database.read { try fetchFolder(id: id, in: $0) }
    }

    public func fetchFolder(id: FolderID, in tx: StoreTransaction) throws -> FolderRecord? {
        try FolderRecord.fetchOne(tx.db, key: id.uuidString)
    }

    /// Every folder in the sidebar order (`sort_order`, then name).
    public func fetchFolderRecords(in tx: StoreTransaction) throws -> [FolderRecord] {
        try Self.orderedFolders().fetchAll(tx.db)
    }

    /// Every folder in the sidebar order, with its live item counts.
    public func fetchFolders() throws -> [FolderModel] {
        try database.read { try Self.folderModels(db: $0.db) }
    }

    /// The folders with their counts, now and after each change (the sidebar).
    public func observeFolders() -> AsyncThrowingStream<[FolderModel], any Error> {
        database.observe { db in
            try Self.folderModels(db: db)
        }
    }

    /// One past the largest `sort_order`, so a new folder goes last.
    public func nextSortOrder(in tx: StoreTransaction) throws -> Int {
        let largest = try FolderRecord.select(max(FolderRecord.CodingKeys.sortOrder), as: Int?.self).fetchOne(tx.db)
        return (largest ?? nil).map { $0 + 1 } ?? 0
    }

    /// Inserts a folder. Throws ``StoreError/constraintViolation(_:)`` with `.unique` when
    /// another folder has the same `name_key`.
    public func insertFolder(_ folder: FolderRecord, in tx: StoreTransaction) throws {
        try folder.insert(tx.db)
    }

    /// Replaces a folder row. Throws ``StoreError/notFound`` if there is none.
    public func updateFolder(_ folder: FolderRecord, in tx: StoreTransaction) throws {
        guard try FolderRecord.exists(tx.db, key: folder.id.uuidString) else {
            throw StoreError.notFound
        }
        try folder.update(tx.db)
    }

    /// Removes a folder and its items. Returns false if there was none.
    @discardableResult
    public func deleteFolder(id: FolderID, in tx: StoreTransaction) throws -> Bool {
        try FolderRecord.deleteOne(tx.db, key: id.uuidString)
    }

    // MARK: - Items: full records (ciphertext)

    public func fetchItemRecord(id: ConfigItemID) throws -> FolderItemRecord? {
        try database.read { try fetchItemRecord(id: id, in: $0) }
    }

    public func fetchItemRecord(id: ConfigItemID, in tx: StoreTransaction) throws -> FolderItemRecord? {
        try FolderItemRecord.fetchOne(tx.db, key: id.uuidString)
    }

    /// The rows of one folder, ordered by name then kind.
    public func fetchItemRecords(folderID: FolderID, in tx: StoreTransaction) throws -> [FolderItemRecord] {
        try FolderItemRecord
            .filter(FolderItemRecord.CodingKeys.folderID == folderID.uuidString)
            .order(FolderItemRecord.CodingKeys.name, FolderItemRecord.CodingKeys.kind)
            .fetchAll(tx.db)
    }

    /// Ids of every folder item in a stable order (DEK rotation rewrites one at a time).
    public func fetchItemIDs() throws -> [ConfigItemID] {
        try database.read { tx in
            try FolderItemRecord
                .select(FolderItemRecord.CodingKeys.id, as: String.self)
                .order(FolderItemRecord.CodingKeys.id)
                .fetchAll(tx.db)
                .compactMap { ConfigItemID(uuidString: $0) }
        }
    }

    /// Inserts an item. Throws ``StoreError/constraintViolation(_:)``: `.unique` for a name the
    /// folder already has for that kind, `.foreignKey` for a missing folder, `.check` for a
    /// lowercase name.
    public func insertItem(_ item: FolderItemRecord, in tx: StoreTransaction) throws {
        try item.insert(tx.db)
    }

    /// Replaces an item row. Throws ``StoreError/notFound`` if there is none.
    public func updateItem(_ item: FolderItemRecord, in tx: StoreTransaction) throws {
        guard try FolderItemRecord.exists(tx.db, key: item.id.uuidString) else {
            throw StoreError.notFound
        }
        try item.update(tx.db)
    }

    @discardableResult
    public func deleteItem(id: ConfigItemID, in tx: StoreTransaction) throws -> Bool {
        try FolderItemRecord.deleteOne(tx.db, key: id.uuidString)
    }

    // MARK: - Items: models (no ciphertext)

    /// The items of one folder with their link counts.
    public func fetchItems(folderID: FolderID) throws -> [FolderItemModel] {
        try database.read { try Self.itemModels(folderID: folderID, db: $0.db) }
    }

    /// The items of one folder, now and after each change, with their link counts (which
    /// follow repository items too).
    public func observeItems(folderID: FolderID) -> AsyncThrowingStream<[FolderItemModel], any Error> {
        database.observe { db in
            try Self.itemModels(folderID: folderID, db: db)
        }
    }

    // MARK: - Linked copies

    /// The folder items of a link group (repository items are in ``ConfigStore``).
    public func fetchLinkedItemRecords(linkID: ItemLinkID, in tx: StoreTransaction) throws -> [FolderItemRecord] {
        try FolderItemRecord
            .filter(FolderItemRecord.CodingKeys.linkID == linkID.uuidString)
            .order(FolderItemRecord.CodingKeys.folderID, FolderItemRecord.CodingKeys.name)
            .fetchAll(tx.db)
    }

    /// Sets `link_id` on folder items only (values and AADs stay as they are).
    public func setLinkID(_ linkID: ItemLinkID?, itemIDs: [ConfigItemID], in tx: StoreTransaction) throws {
        guard !itemIDs.isEmpty else { return }
        try FolderItemRecord
            .filter(keys: itemIDs.map(\.uuidString))
            .updateAll(tx.db, FolderItemRecord.CodingKeys.linkID.set(to: linkID?.uuidString))
    }

    // MARK: - Queries

    private static func orderedFolders() -> QueryInterfaceRequest<FolderRecord> {
        FolderRecord.order(FolderRecord.CodingKeys.sortOrder, FolderRecord.CodingKeys.nameKey)
    }

    static func folderModels(db: Database) throws -> [FolderModel] {
        let folders = try orderedFolders().fetchAll(db)
        let rows = try Row.fetchAll(
            db,
            FolderItemRecord
                .select(FolderItemRecord.CodingKeys.folderID, FolderItemRecord.CodingKeys.kind, count(FolderItemRecord.CodingKeys.id))
                .group(FolderItemRecord.CodingKeys.folderID, FolderItemRecord.CodingKeys.kind)
        )
        var counts: [String: [ConfigKind: Int]] = [:]
        for row in rows {
            guard let folder: String = row[0], let kindText: String = row[1], let kind = ConfigKind(rawValue: kindText) else {
                continue
            }
            counts[folder, default: [:]][kind] = row[2]
        }
        return folders.map { folder in
            let byKind = counts[folder.id.uuidString] ?? [:]
            return folder.model(secretCount: byKind[.secret] ?? 0, variableCount: byKind[.variable] ?? 0)
        }
    }

    static func itemModels(folderID: FolderID, db: Database) throws -> [FolderItemModel] {
        let records = try FolderItemRecord
            .filter(FolderItemRecord.CodingKeys.folderID == folderID.uuidString)
            .order(FolderItemRecord.CodingKeys.name, FolderItemRecord.CodingKeys.kind)
            .fetchAll(db)
        let counts = try LinkCountQuery.counts(of: Set(records.compactMap(\.linkID)), db: db)
        return records.map { $0.model(linkCount: $0.linkID.flatMap { counts[$0] } ?? 0) }
    }
}

/// Live members of link groups across `config_items` (not deleted) and `folder_items` (v0.7.0).
enum LinkCountQuery {
    static func counts(of linkIDs: Set<ItemLinkID>, db: Database) throws -> [ItemLinkID: Int] {
        guard !linkIDs.isEmpty else { return [:] }
        let texts = linkIDs.map(\.uuidString)
        var counts: [ItemLinkID: Int] = [:]
        let requests: [SQLRequest<Row>] = [
            SQLRequest(literal: """
                SELECT link_id, COUNT(id) FROM config_items
                WHERE is_deleted = 0 AND link_id IN \(texts) GROUP BY link_id
                """),
            SQLRequest(literal: """
                SELECT link_id, COUNT(id) FROM folder_items
                WHERE link_id IN \(texts) GROUP BY link_id
                """),
        ]
        for request in requests {
            for row in try request.fetchAll(db) {
                guard let text: String = row[0], let linkID = ItemLinkID(uuidString: text) else { continue }
                counts[linkID, default: 0] += row[1] as Int
            }
        }
        return counts
    }
}
