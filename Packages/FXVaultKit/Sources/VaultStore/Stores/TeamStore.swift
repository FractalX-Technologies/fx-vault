import Foundation
import GRDB
import VaultCore

/// `device_identity` and `teammates` (§6 `v10_teammates`, v0.5.0). Ciphertexts are opaque here:
/// VaultData seals and opens them through `VaultSession`.
public struct TeamStore: Sendable {
    public let database: VaultDatabase

    public init(database: VaultDatabase) {
        self.database = database
    }

    // MARK: - This device

    public func fetchIdentity(in tx: StoreTransaction) throws -> DeviceIdentityRecord? {
        try DeviceIdentityRecord.fetchOne(tx.db, key: DeviceIdentityRecord.singletonID)
    }

    /// Inserts or replaces the single row.
    public func saveIdentity(_ record: DeviceIdentityRecord, in tx: StoreTransaction) throws {
        try record.upsert(tx.db)
    }

    // MARK: - Teammates

    /// Every teammate, by name.
    public func fetchTeammates(in tx: StoreTransaction) throws -> [TeammateRecord] {
        try Self.orderedRequest.fetchAll(tx.db)
    }

    public func fetchTeammate(deviceID: String, in tx: StoreTransaction) throws -> TeammateRecord? {
        try TeammateRecord.fetchOne(tx.db, key: deviceID)
    }

    /// Inserts a teammate, or replaces the row of a device paired again.
    public func saveTeammate(_ record: TeammateRecord, in tx: StoreTransaction) throws {
        try record.upsert(tx.db)
    }

    /// Removes a teammate. Returns false when there was none.
    @discardableResult
    public func deleteTeammate(deviceID: String, in tx: StoreTransaction) throws -> Bool {
        try TeammateRecord.deleteOne(tx.db, key: deviceID)
    }

    /// Sets `needs_card_update` on every teammate (this device's announce key changed).
    public func markAllNeedCardUpdate(in tx: StoreTransaction) throws {
        try TeammateRecord.updateAll(tx.db, TeammateRecord.CodingKeys.needsCardUpdate.set(to: true))
    }

    /// Teammates without keys, by name, now and after each change.
    public func observeTeammates() -> AsyncThrowingStream<[TeammateModel], any Error> {
        database.observe { db in
            try Self.orderedRequest.fetchAll(db).map(\.model)
        }
    }

    /// Teammates without keys, read now.
    public func fetchTeammateModels() throws -> [TeammateModel] {
        try database.read { tx in try Self.orderedRequest.fetchAll(tx.db).map(\.model) }
    }

    /// Updates the plain columns of one teammate (seen, muted, card update sent).
    public func updateTeammate(
        deviceID: String,
        in tx: StoreTransaction,
        _ change: (inout TeammateRecord) -> Void
    ) throws {
        guard var record = try fetchTeammate(deviceID: deviceID, in: tx) else { throw StoreError.notFound }
        change(&record)
        try record.update(tx.db)
    }

    private static var orderedRequest: QueryInterfaceRequest<TeammateRecord> {
        TeammateRecord.order(
            TeammateRecord.CodingKeys.displayName.collating(.localizedCaseInsensitiveCompare),
            TeammateRecord.CodingKeys.deviceID
        )
    }
}
