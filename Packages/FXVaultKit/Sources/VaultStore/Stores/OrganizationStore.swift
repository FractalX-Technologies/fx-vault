import Foundation
import GRDB
import VaultCore

/// `organizations` and `org_items` (§6 `v17_organizations`, 1.0).
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
