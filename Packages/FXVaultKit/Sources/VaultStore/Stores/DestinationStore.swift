import Foundation
import GRDB
import VaultCore

/// `destinations`, `destination_items`, `provider_connections` and `destination_journal`
/// (§6 `v13_destinations`, v0.8.0).
///
/// No GitHub sync path reads these tables: destination items reach their provider only through
/// VaultData's destination sync. Link groups (`link_id`) span `config_items`, `folder_items` and
/// `destination_items`.
public struct DestinationStore: Sendable {
    public let database: VaultDatabase

    public init(database: VaultDatabase) {
        self.database = database
    }

    // MARK: - Destinations

    public func fetchDestination(id: DestinationID, in tx: StoreTransaction) throws -> DestinationRecord? {
        try DestinationRecord.fetchOne(tx.db, key: id.uuidString)
    }

    public func fetchDestination(id: DestinationID) throws -> DestinationRecord? {
        try database.read { try fetchDestination(id: id, in: $0) }
    }

    /// The destinations of one repository in the sidebar order.
    public func fetchDestinationRecords(repositoryID: RepoID, in tx: StoreTransaction) throws -> [DestinationRecord] {
        try Self.orderedDestinations(repositoryID: repositoryID).fetchAll(tx.db)
    }

    /// Every destination of the vault (connection removal, diagnostics).
    public func fetchAllDestinationRecords(in tx: StoreTransaction) throws -> [DestinationRecord] {
        try DestinationRecord.order(DestinationRecord.CodingKeys.repositoryID, DestinationRecord.CodingKeys.sortOrder).fetchAll(tx.db)
    }

    /// The destinations of one repository with their counts.
    public func fetchDestinations(repositoryID: RepoID) throws -> [DestinationModel] {
        try database.read { try Self.destinationModels(repositoryID: repositoryID, db: $0.db) }
    }

    /// The destinations of one repository with their counts, now and after each change.
    public func observeDestinations(repositoryID: RepoID) -> AsyncThrowingStream<[DestinationModel], any Error> {
        database.observe { db in
            try Self.destinationModels(repositoryID: repositoryID, db: db)
        }
    }

    /// Pending destination changes per repository (the Sync badge), now and after each change.
    public func observePendingCounts() -> AsyncThrowingStream<[RepoID: Int], any Error> {
        database.observe { db in
            try Self.pendingCounts(db: db)
        }
    }

    /// Pending destination changes per repository.
    public func fetchPendingCounts() throws -> [RepoID: Int] {
        try database.read { try Self.pendingCounts(db: $0.db) }
    }

    /// One past the largest `sort_order` of the repository's destinations.
    public func nextSortOrder(repositoryID: RepoID, in tx: StoreTransaction) throws -> Int {
        let largest = try DestinationRecord
            .filter(DestinationRecord.CodingKeys.repositoryID == repositoryID.uuidString)
            .select(max(DestinationRecord.CodingKeys.sortOrder), as: Int?.self)
            .fetchOne(tx.db)
        return (largest ?? nil).map { $0 + 1 } ?? 0
    }

    public func countDestinations(repositoryID: RepoID, in tx: StoreTransaction) throws -> Int {
        try DestinationRecord.filter(DestinationRecord.CodingKeys.repositoryID == repositoryID.uuidString).fetchCount(tx.db)
    }

    /// Inserts a destination. Throws `.constraintViolation(.unique)` when the repository already
    /// has the same target.
    public func insertDestination(_ destination: DestinationRecord, in tx: StoreTransaction) throws {
        try destination.insert(tx.db)
    }

    public func updateDestination(_ destination: DestinationRecord, in tx: StoreTransaction) throws {
        guard try DestinationRecord.exists(tx.db, key: destination.id.uuidString) else {
            throw StoreError.notFound
        }
        try destination.update(tx.db)
    }

    /// Removes a destination and its items (nothing is deleted remotely).
    @discardableResult
    public func deleteDestination(id: DestinationID, in tx: StoreTransaction) throws -> Bool {
        try DestinationRecord.deleteOne(tx.db, key: id.uuidString)
    }

    // MARK: - Items: full records (ciphertext)

    public func fetchItemRecord(id: ConfigItemID, in tx: StoreTransaction) throws -> DestinationItemRecord? {
        try DestinationItemRecord.fetchOne(tx.db, key: id.uuidString)
    }

    public func fetchItemRecord(id: ConfigItemID) throws -> DestinationItemRecord? {
        try database.read { try fetchItemRecord(id: id, in: $0) }
    }

    /// Every row of one destination, tombstones included, by name.
    public func fetchItemRecords(destinationID: DestinationID, in tx: StoreTransaction) throws -> [DestinationItemRecord] {
        try DestinationItemRecord
            .filter(DestinationItemRecord.CodingKeys.destinationID == destinationID.uuidString)
            .order(DestinationItemRecord.CodingKeys.name)
            .fetchAll(tx.db)
    }

    /// The row holding `name` (any case) in the destination, tombstone or not.
    public func fetchItemRecord(destinationID: DestinationID, name: String, in tx: StoreTransaction) throws -> DestinationItemRecord? {
        try DestinationItemRecord
            .filter(DestinationItemRecord.CodingKeys.destinationID == destinationID.uuidString)
            .filter(DestinationItemRecord.CodingKeys.name == name.uppercased())
            .fetchOne(tx.db)
    }

    /// Ids of every destination item in a stable order (DEK rotation rewrites one at a time).
    public func fetchItemIDs() throws -> [ConfigItemID] {
        try database.read { tx in
            try DestinationItemRecord
                .select(DestinationItemRecord.CodingKeys.id, as: String.self)
                .order(DestinationItemRecord.CodingKeys.id)
                .fetchAll(tx.db)
                .compactMap { ConfigItemID(uuidString: $0) }
        }
    }

    /// Live (not deleted) items of one destination.
    public func countLiveItems(destinationID: DestinationID, in tx: StoreTransaction) throws -> Int {
        try DestinationItemRecord
            .filter(DestinationItemRecord.CodingKeys.destinationID == destinationID.uuidString)
            .filter(DestinationItemRecord.CodingKeys.isDeleted == false)
            .fetchCount(tx.db)
    }

    /// Inserts an item. Throws `.constraintViolation(.unique)` for a name the destination
    /// already has, `.foreignKey` for a missing destination, `.check` for a lowercase name.
    public func insertItem(_ item: DestinationItemRecord, in tx: StoreTransaction) throws {
        try item.insert(tx.db)
    }

    public func updateItem(_ item: DestinationItemRecord, in tx: StoreTransaction) throws {
        guard try DestinationItemRecord.exists(tx.db, key: item.id.uuidString) else {
            throw StoreError.notFound
        }
        try item.update(tx.db)
    }

    @discardableResult
    public func deleteItem(id: ConfigItemID, in tx: StoreTransaction) throws -> Bool {
        try DestinationItemRecord.deleteOne(tx.db, key: id.uuidString)
    }

    // MARK: - Items: states and models (no ciphertext)

    /// The sync facts of every row of the given destinations.
    public func fetchItemStates(destinationIDs: [DestinationID], in tx: StoreTransaction) throws -> [DestinationItemState] {
        try Self.itemStates(destinationIDs: destinationIDs, db: tx.db)
    }

    /// The items of one destination (tombstones included, shown as Deleted) with link counts.
    public func fetchItems(destinationID: DestinationID) throws -> [DestinationItemModel] {
        try database.read { try Self.itemModels(destinationID: destinationID, db: $0.db) }
    }

    /// The items of one destination, now and after each change.
    public func observeItems(destinationID: DestinationID) -> AsyncThrowingStream<[DestinationItemModel], any Error> {
        database.observe { db in
            try Self.itemModels(destinationID: destinationID, db: db)
        }
    }

    // MARK: - Linked copies

    /// The destination items of a link group (repository and folder items are in their stores).
    public func fetchLinkedItemRecords(linkID: ItemLinkID, in tx: StoreTransaction) throws -> [DestinationItemRecord] {
        try DestinationItemRecord
            .filter(DestinationItemRecord.CodingKeys.linkID == linkID.uuidString)
            .filter(DestinationItemRecord.CodingKeys.isDeleted == false)
            .order(DestinationItemRecord.CodingKeys.destinationID, DestinationItemRecord.CodingKeys.name)
            .fetchAll(tx.db)
    }

    /// Sets `link_id` on destination items only (values and AADs stay as they are).
    public func setLinkID(_ linkID: ItemLinkID?, itemIDs: [ConfigItemID], in tx: StoreTransaction) throws {
        guard !itemIDs.isEmpty else { return }
        try DestinationItemRecord
            .filter(keys: itemIDs.map(\.uuidString))
            .updateAll(tx.db, DestinationItemRecord.CodingKeys.linkID.set(to: linkID?.uuidString))
    }

    // MARK: - Connections

    public func fetchConnection(id: ConnectionID, in tx: StoreTransaction) throws -> ConnectionRecord? {
        try ConnectionRecord.fetchOne(tx.db, key: id.uuidString)
    }

    public func fetchConnectionRecords(in tx: StoreTransaction) throws -> [ConnectionRecord] {
        try ConnectionRecord.order(ConnectionRecord.CodingKeys.provider, ConnectionRecord.CodingKeys.label).fetchAll(tx.db)
    }

    public func fetchConnections() throws -> [ConnectionModel] {
        try database.read { try fetchConnectionRecords(in: $0).map(\.model) }
    }

    public func observeConnections() -> AsyncThrowingStream<[ConnectionModel], any Error> {
        database.observe { db in
            try ConnectionRecord.order(ConnectionRecord.CodingKeys.provider, ConnectionRecord.CodingKeys.label)
                .fetchAll(db)
                .map(\.model)
        }
    }

    public func countConnections(in tx: StoreTransaction) throws -> Int {
        try ConnectionRecord.fetchCount(tx.db)
    }

    public func insertConnection(_ connection: ConnectionRecord, in tx: StoreTransaction) throws {
        try connection.insert(tx.db)
    }

    public func updateConnection(_ connection: ConnectionRecord, in tx: StoreTransaction) throws {
        guard try ConnectionRecord.exists(tx.db, key: connection.id.uuidString) else {
            throw StoreError.notFound
        }
        try connection.update(tx.db)
    }

    /// Removes a connection; its destinations keep their rows with no connection.
    @discardableResult
    public func deleteConnection(id: ConnectionID, in tx: StoreTransaction) throws -> Bool {
        try ConnectionRecord.deleteOne(tx.db, key: id.uuidString)
    }

    /// Ids of every connection (DEK rotation).
    public func fetchConnectionIDs() throws -> [ConnectionID] {
        try database.read { tx in
            try ConnectionRecord
                .select(ConnectionRecord.CodingKeys.id, as: String.self)
                .order(ConnectionRecord.CodingKeys.id)
                .fetchAll(tx.db)
                .compactMap { ConnectionID(uuidString: $0) }
        }
    }

    // MARK: - Journal

    /// Records a write before it starts and returns the row with its id.
    public func appendJournal(_ entry: DestinationJournalRecord, in tx: StoreTransaction) throws -> DestinationJournalRecord {
        var entry = entry
        try entry.insert(tx.db)
        return entry
    }

    public func updateJournal(_ entry: DestinationJournalRecord, in tx: StoreTransaction) throws {
        try entry.update(tx.db)
    }

    /// Every journal row, oldest first (diagnostics and tests).
    public func fetchJournal() throws -> [DestinationJournalRecord] {
        try database.read { tx in
            try DestinationJournalRecord.order(DestinationJournalRecord.CodingKeys.id).fetchAll(tx.db)
        }
    }

    /// Rows still in flight or indeterminate (reconciled by the next listing).
    public func fetchUnresolvedJournal(destinationID: DestinationID, in tx: StoreTransaction) throws -> [DestinationJournalRecord] {
        try DestinationJournalRecord
            .filter(DestinationJournalRecord.CodingKeys.destinationID == destinationID.uuidString)
            .filter([DestinationJournalRecord.State.inFlight.rawValue, DestinationJournalRecord.State.indeterminate.rawValue]
                .contains(DestinationJournalRecord.CodingKeys.state))
            .order(DestinationJournalRecord.CodingKeys.id)
            .fetchAll(tx.db)
    }

    /// Names deleted from the destination since `since` by FX Vault, so drift does not report
    /// them as remote adds while the provider still lists them.
    public func recentlyDeletedNames(destinationID: DestinationID, since: Date, in tx: StoreTransaction) throws -> Set<String> {
        let rows = try DestinationJournalRecord
            .filter(DestinationJournalRecord.CodingKeys.destinationID == destinationID.uuidString)
            .filter(DestinationJournalRecord.CodingKeys.operation == DestinationJournalRecord.Operation.delete.rawValue)
            .filter(DestinationJournalRecord.CodingKeys.state == DestinationJournalRecord.State.succeeded.rawValue)
            .filter(DestinationJournalRecord.CodingKeys.startedAt >= DatabaseTimestamp.string(from: since))
            .fetchAll(tx.db)
        return Set(rows.map(\.itemName))
    }

    /// Deletes resolved rows older than the journal retention.
    @discardableResult
    public func pruneJournal(now: Date, in tx: StoreTransaction) throws -> Int {
        let cutoff = DatabaseTimestamp.string(from: now - Timeouts.syncJournalRetention.timeInterval)
        return try DestinationJournalRecord
            .filter(DestinationJournalRecord.CodingKeys.startedAt < cutoff)
            .filter(DestinationJournalRecord.CodingKeys.state != DestinationJournalRecord.State.inFlight.rawValue)
            .deleteAll(tx.db)
    }

    // MARK: - Queries

    private static func orderedDestinations(repositoryID: RepoID) -> QueryInterfaceRequest<DestinationRecord> {
        DestinationRecord
            .filter(DestinationRecord.CodingKeys.repositoryID == repositoryID.uuidString)
            .order(DestinationRecord.CodingKeys.sortOrder, DestinationRecord.CodingKeys.targetKey)
    }

    static func itemStates(destinationIDs: [DestinationID], db: Database) throws -> [DestinationItemState] {
        guard !destinationIDs.isEmpty else { return [] }
        let ids = destinationIDs.map(\.uuidString)
        return try DestinationItemState.fetchAll(db, SQLRequest(literal: """
            SELECT \(sql: DestinationItemState.selection) FROM destination_items
            WHERE destination_id IN \(ids) ORDER BY name
            """))
    }

    static func destinationModels(repositoryID: RepoID, db: Database) throws -> [DestinationModel] {
        let destinations = try orderedDestinations(repositoryID: repositoryID).fetchAll(db)
        let states = try itemStates(destinationIDs: destinations.map(\.id), db: db)
        let byDestination = Dictionary(grouping: states, by: \.destinationID)
        return try destinations.map { destination in
            let rows = byDestination[destination.id] ?? []
            let live = rows.filter { !$0.isDeleted }
            return try destination.model(
                secretCount: live.count { $0.kind == .secret },
                variableCount: live.count { $0.kind == .variable },
                pendingCount: rows.count { $0.pendingOperation != nil },
                valueMissingCount: live.count { !$0.hasValue }
            )
        }
    }

    static func pendingCounts(db: Database) throws -> [RepoID: Int] {
        let destinations = try DestinationRecord.fetchAll(db)
        guard !destinations.isEmpty else { return [:] }
        let repositoryOf = Dictionary(uniqueKeysWithValues: destinations.map { ($0.id, $0.repositoryID) })
        let states = try itemStates(destinationIDs: destinations.map(\.id), db: db)
        var counts: [RepoID: Int] = [:]
        for state in states where state.pendingOperation != nil {
            guard let repositoryID = repositoryOf[state.destinationID] else { continue }
            counts[repositoryID, default: 0] += 1
        }
        return counts
    }

    static func itemModels(destinationID: DestinationID, db: Database) throws -> [DestinationItemModel] {
        let records = try DestinationItemRecord
            .filter(DestinationItemRecord.CodingKeys.destinationID == destinationID.uuidString)
            .order(DestinationItemRecord.CodingKeys.name)
            .fetchAll(db)
        let counts = try LinkCountQuery.counts(of: Set(records.compactMap(\.linkID)), db: db)
        return records.map { $0.model(linkCount: $0.linkID.flatMap { counts[$0] } ?? 0) }
    }
}
