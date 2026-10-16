import Foundation
import GRDB
import VaultCore

/// `spaces`, `space_keys`, `space_versions` and `teammate_addresses` (§6 `v11_spaces`, v0.6.0).
/// Versions are append-only: a row is never updated, and only removing the space removes them.
public struct SpaceStore: Sendable {
    public let database: VaultDatabase

    public init(database: VaultDatabase) {
        self.database = database
    }

    // MARK: - Spaces

    public func fetchSpace(id: SpaceID, in tx: StoreTransaction) throws -> SpaceRecord? {
        try SpaceRecord.fetchOne(tx.db, key: id.uuidString)
    }

    public func fetchSpace(repositoryID: RepoID, scope: ConfigScope, in tx: StoreTransaction) throws -> SpaceRecord? {
        var request = SpaceRecord.filter(SpaceRecord.CodingKeys.repositoryID == repositoryID.uuidString)
        switch scope {
        case .repository:
            request = request.filter(SpaceRecord.CodingKeys.environmentID == nil)
        case .environment(let id):
            request = request.filter(SpaceRecord.CodingKeys.environmentID == id.uuidString)
        }
        return try request.fetchOne(tx.db)
    }

    public func fetchSpaces(repositoryID: RepoID? = nil, in tx: StoreTransaction) throws -> [SpaceRecord] {
        var request = SpaceRecord.order(SpaceRecord.CodingKeys.createdAt)
        if let repositoryID {
            request = request.filter(SpaceRecord.CodingKeys.repositoryID == repositoryID.uuidString)
        }
        return try request.fetchAll(tx.db)
    }

    public func fetchSpaces() throws -> [SpaceRecord] {
        try database.read { try fetchSpaces(in: $0) }
    }

    public func saveSpace(_ record: SpaceRecord, in tx: StoreTransaction) throws {
        try record.upsert(tx.db)
    }

    @discardableResult
    public func deleteSpace(id: SpaceID, in tx: StoreTransaction) throws -> Bool {
        try SpaceRecord.deleteOne(tx.db, key: id.uuidString)
    }

    /// Every space, now and after each change (the scope chips and the Sync sheet).
    public func observeSpaces() -> AsyncThrowingStream<[SpaceRecord], any Error> {
        database.observe { db in
            try SpaceRecord.order(SpaceRecord.CodingKeys.createdAt).fetchAll(db)
        }
    }

    // MARK: - Keys

    public func fetchKeys(spaceID: SpaceID, in tx: StoreTransaction) throws -> [SpaceKeyRecord] {
        try SpaceKeyRecord
            .filter(SpaceKeyRecord.CodingKeys.spaceID == spaceID.uuidString)
            .order(SpaceKeyRecord.CodingKeys.epoch)
            .fetchAll(tx.db)
    }

    public func fetchAllKeys(in tx: StoreTransaction) throws -> [SpaceKeyRecord] {
        try SpaceKeyRecord.fetchAll(tx.db)
    }

    public func saveKey(_ record: SpaceKeyRecord, in tx: StoreTransaction) throws {
        try record.upsert(tx.db)
    }

    // MARK: - Versions

    /// The versions of a space after `version` (all of them by default), in order.
    public func fetchVersions(spaceID: SpaceID, after version: Int64 = 0, in tx: StoreTransaction) throws -> [SpaceVersionRecord] {
        try SpaceVersionRecord
            .filter(SpaceVersionRecord.CodingKeys.spaceID == spaceID.uuidString)
            .filter(SpaceVersionRecord.CodingKeys.version > version)
            .order(SpaceVersionRecord.CodingKeys.version)
            .fetchAll(tx.db)
    }

    /// Appends a verified version. A second row for the same number is a constraint violation.
    public func appendVersion(_ record: SpaceVersionRecord, in tx: StoreTransaction) throws {
        try record.insert(tx.db)
    }

    // MARK: - Teammate addresses (Q4)

    public func fetchAddresses(in tx: StoreTransaction) throws -> [TeammateAddressRecord] {
        try TeammateAddressRecord.fetchAll(tx.db)
    }

    public func fetchAddresses() throws -> [TeammateAddressRecord] {
        try database.read { try fetchAddresses(in: $0) }
    }

    /// Every row, now and after each change (Preferences › Teammates).
    public func observeAddresses() -> AsyncThrowingStream<[TeammateAddressRecord], any Error> {
        database.observe { db in
            try TeammateAddressRecord.order(TeammateAddressRecord.CodingKeys.deviceID).fetchAll(db)
        }
    }

    public func saveAddress(_ record: TeammateAddressRecord, in tx: StoreTransaction) throws {
        try record.upsert(tx.db)
    }

    @discardableResult
    public func deleteAddress(deviceID: String, in tx: StoreTransaction) throws -> Bool {
        try TeammateAddressRecord.deleteOne(tx.db, key: deviceID)
    }
}
