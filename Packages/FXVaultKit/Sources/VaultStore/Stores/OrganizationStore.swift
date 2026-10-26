import Foundation
import GRDB
import VaultCore

/// `organizations`, `org_items` and `org_item_repositories` (§6 `v17_organizations`,
/// `v19_org_item_changes`, 1.0).
public struct OrganizationStore: Sendable {
    public let database: VaultDatabase

    public init(database: VaultDatabase) {
        self.database = database
    }

    // MARK: - Organizations

    public func fetchOrganization(id: OrganizationID, in tx: StoreTransaction) throws -> OrganizationRecord? {
        try OrganizationRecord.fetchOne(tx.db, key: id.uuidString)
    }

    /// The organization with `login` (any case), if it is in the vault.
    public func fetchOrganization(login: String) throws -> OrganizationRecord? {
        try database.read { tx in
            try OrganizationRecord
                .filter(OrganizationRecord.CodingKeys.loginKey == OwnerLoginValidator.foldKey(login))
                .fetchOne(tx.db)
        }
    }

    /// Every organization by login (DEK rotation walks them).
    public func fetchOrganizationRecords(in tx: StoreTransaction) throws -> [OrganizationRecord] {
        try OrganizationRecord.order(OrganizationRecord.CodingKeys.loginKey).fetchAll(tx.db)
    }

    /// Every organization by login, with its live item counts.
    public func fetchOrganizations() throws -> [OrganizationModel] {
        try database.read { try Self.organizationModels(db: $0.db) }
    }

    /// The organizations with their counts, now and after each change (the sidebar).
    public func observeOrganizations() -> AsyncThrowingStream<[OrganizationModel], any Error> {
        database.observe { db in
            try Self.organizationModels(db: db)
        }
    }

    /// Throws ``StoreError/constraintViolation(_:)`` with `.unique` when the login is already in
    /// the vault.
    public func insertOrganization(_ organization: OrganizationRecord, in tx: StoreTransaction) throws {
        try organization.insert(tx.db)
    }

    /// Records when Refresh listed the organization; nothing else of the row changes.
    public func recordRefresh(organizationID: OrganizationID, at date: Date, in tx: StoreTransaction) throws {
        try OrganizationRecord
            .filter(key: organizationID.uuidString)
            .updateAll(tx.db, OrganizationRecord.CodingKeys.lastRefreshedAt.set(to: DatabaseTimestamp.string(from: date)))
    }

    /// Removes an organization and its items. Returns false if there was none.
    @discardableResult
    public func deleteOrganization(id: OrganizationID) throws -> Bool {
        try database.write { tx in
            try OrganizationRecord.deleteOne(tx.db, key: id.uuidString)
        }
    }

    // MARK: - Items

    /// The rows of one organization (ciphertext included), ordered by name then kind.
    public func fetchItemRecords(organizationID: OrganizationID, in tx: StoreTransaction) throws -> [OrgItemRecord] {
        try Self.orderedItems(organizationID: organizationID).fetchAll(tx.db)
    }

    public func fetchItemRecord(id: ConfigItemID, in tx: StoreTransaction) throws -> OrgItemRecord? {
        try OrgItemRecord.fetchOne(tx.db, key: id.uuidString)
    }

    /// The items of one organization (no ciphertext).
    public func fetchItems(organizationID: OrganizationID) throws -> [OrgItemModel] {
        try database.read { try Self.orderedItems(organizationID: organizationID).fetchAll($0.db).map(\.model) }
    }

    /// The items of one organization, now and after each change.
    public func observeItems(organizationID: OrganizationID) -> AsyncThrowingStream<[OrgItemModel], any Error> {
        database.observe { db in
            try Self.orderedItems(organizationID: organizationID).fetchAll(db).map(\.model)
        }
    }

    /// Throws ``StoreError/constraintViolation(_:)``: `.unique` for a name the organization
    /// already has for that kind, `.check` for a lowercase name or a variable without a value.
    public func insertItem(_ item: OrgItemRecord, in tx: StoreTransaction) throws {
        try item.insert(tx.db)
    }

    /// The row of `name` (exact, names are uppercase) for `kind`, tombstones included.
    public func fetchItemRecord(organizationID: OrganizationID, kind: ConfigKind, name: String, in tx: StoreTransaction) throws -> OrgItemRecord? {
        try OrgItemRecord
            .filter(OrgItemRecord.CodingKeys.organizationID == organizationID.uuidString)
            .filter(OrgItemRecord.CodingKeys.kind == kind.rawValue)
            .filter(OrgItemRecord.CodingKeys.name == name)
            .fetchOne(tx.db)
    }

    public func countItems(organizationID: OrganizationID, kind: ConfigKind, in tx: StoreTransaction) throws -> Int {
        try OrgItemRecord
            .filter(OrgItemRecord.CodingKeys.organizationID == organizationID.uuidString)
            .filter(OrgItemRecord.CodingKeys.kind == kind.rawValue)
            .fetchCount(tx.db)
    }

    @discardableResult
    public func deleteItem(id: ConfigItemID, in tx: StoreTransaction) throws -> Bool {
        try OrgItemRecord.deleteOne(tx.db, key: id.uuidString)
    }

    /// The live items of the organization `ownerLogin` that reach one of its repositories (B7a),
    /// now and after each change; nil while that organization is not in the vault.
    public func observeInheritedItems(
        ownerLogin: String,
        repositoryName: String,
        isPrivate: Bool
    ) -> AsyncThrowingStream<InheritedOrgItemsModel?, any Error> {
        database.observe { db in
            try Self.inheritedItems(ownerLogin: ownerLogin, repositoryName: repositoryName, isPrivate: isPrivate, db: db)
        }
    }

    public func fetchInheritedItems(ownerLogin: String, repositoryName: String, isPrivate: Bool) throws -> InheritedOrgItemsModel? {
        try database.read { tx in
            try Self.inheritedItems(ownerLogin: ownerLogin, repositoryName: repositoryName, isPrivate: isPrivate, db: tx.db)
        }
    }

    /// A `selected` item reaches the repository only through the list stored for it: GitHub's
    /// own list is not read at import, so an unknown list reaches nothing.
    static func inheritedItems(ownerLogin: String, repositoryName: String, isPrivate: Bool, db: Database) throws -> InheritedOrgItemsModel? {
        guard let organization = try OrganizationRecord
            .filter(OrganizationRecord.CodingKeys.loginKey == OwnerLoginValidator.foldKey(ownerLogin))
            .fetchOne(db)
        else { return nil }
        var items: [OrgItemModel] = []
        for record in try orderedItems(organizationID: organization.id).fetchAll(db) where !record.isDeleted {
            let selected = record.visibility == .selected
                ? try String.fetchAll(db, sql: "SELECT name FROM org_item_repositories WHERE item_id = ?", arguments: [record.id.uuidString])
                : []
            if record.visibility.reaches(repositoryName: repositoryName, isPrivate: isPrivate, selectedRepositories: selected) {
                items.append(record.model)
            }
        }
        return InheritedOrgItemsModel(organizationID: organization.id, organizationLogin: organization.login, items: items)
    }

    /// The repository list stored for an item (`repositories_edited`), by name.
    public func fetchRepositories(itemID: ConfigItemID, in tx: StoreTransaction) throws -> [String] {
        try String.fetchAll(
            tx.db,
            sql: "SELECT name FROM org_item_repositories WHERE item_id = ? ORDER BY name COLLATE NOCASE",
            arguments: [itemID.uuidString]
        )
    }

    /// Replaces the item's repository list (empty: none stored).
    public func replaceRepositories(itemID: ConfigItemID, names: [String], in tx: StoreTransaction) throws {
        try tx.db.execute(sql: "DELETE FROM org_item_repositories WHERE item_id = ?", arguments: [itemID.uuidString])
        for name in names {
            try tx.db.execute(sql: "INSERT INTO org_item_repositories (item_id, name) VALUES (?, ?)", arguments: [itemID.uuidString, name])
        }
    }

    /// Pending item changes per organization (the Sync badge), now and after each change.
    public func observePendingCounts() -> AsyncThrowingStream<[OrganizationID: Int], any Error> {
        database.observe { db in
            try Self.pendingCounts(db: db)
        }
    }

    public func fetchPendingCounts() throws -> [OrganizationID: Int] {
        try database.read { try Self.pendingCounts(db: $0.db) }
    }

    /// Replaces an item row. Throws ``StoreError/notFound`` if there is none.
    public func updateItem(_ item: OrgItemRecord, in tx: StoreTransaction) throws {
        guard try OrgItemRecord.exists(tx.db, key: item.id.uuidString) else {
            throw StoreError.notFound
        }
        try item.update(tx.db)
    }

    // MARK: - Queries

    private static func orderedItems(organizationID: OrganizationID) -> QueryInterfaceRequest<OrgItemRecord> {
        OrgItemRecord
            .filter(OrgItemRecord.CodingKeys.organizationID == organizationID.uuidString)
            .order(OrgItemRecord.CodingKeys.name, OrgItemRecord.CodingKeys.kind)
    }

    static func pendingCounts(db: Database) throws -> [OrganizationID: Int] {
        var counts: [OrganizationID: Int] = [:]
        for item in try OrgItemRecord.fetchAll(db) where item.syncStatus != .synced {
            counts[item.organizationID, default: 0] += 1
        }
        return counts
    }

    static func organizationModels(db: Database) throws -> [OrganizationModel] {
        let organizations = try OrganizationRecord.order(OrganizationRecord.CodingKeys.loginKey).fetchAll(db)
        let rows = try Row.fetchAll(
            db,
            OrgItemRecord
                .select(OrgItemRecord.CodingKeys.organizationID, OrgItemRecord.CodingKeys.kind, count(OrgItemRecord.CodingKeys.id))
                .group(OrgItemRecord.CodingKeys.organizationID, OrgItemRecord.CodingKeys.kind)
        )
        var counts: [String: [ConfigKind: Int]] = [:]
        for row in rows {
            guard let organization: String = row[0], let kindText: String = row[1], let kind = ConfigKind(rawValue: kindText) else {
                continue
            }
            counts[organization, default: [:]][kind] = row[2]
        }
        return organizations.map { organization in
            let byKind = counts[organization.id.uuidString] ?? [:]
            return organization.model(secretCount: byKind[.secret] ?? 0, variableCount: byKind[.variable] ?? 0)
        }
    }
}
