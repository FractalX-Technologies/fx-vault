import Foundation
import GRDB

/// The `vaults` row and the `key_wraps` rows (§6 `v1_vault`): what `VaultManager` reads to unlock
/// and writes on create, password change, recovery reset and DEK rotation.
///
/// Named `VaultRecordStore` rather than `VaultStore`: a type named like its module breaks
/// module-qualified lookups (`VaultStore.StoreError`) in every client.
///
/// Key writes and the WAL (D10): the convenience methods without `in:` run their own transaction
/// and then call ``VaultDatabase/checkpointTruncate()``. When you use the `in:` overloads inside
/// your own ``VaultDatabase/write(_:)``, call `checkpointTruncate()` after it returns.
public struct VaultRecordStore: Sendable {
    public let database: VaultDatabase

    public init(database: VaultDatabase) {
        self.database = database
    }

    // MARK: - vaults

    /// The vault row, or nil before onboarding created it.
    public func fetchVault() throws -> VaultRecord? {
        try database.read { try fetchVault(in: $0) }
    }

    public func fetchVault(in tx: StoreTransaction) throws -> VaultRecord? {
        try VaultRecord.fetchOne(tx.db, key: VaultRecord.singletonID)
    }

    /// True once a vault exists.
    public func hasVault() throws -> Bool {
        try fetchVault() != nil
    }

    /// Creates the vault row and its wraps in one transaction, then checkpoints. Throws
    /// ``StoreError/constraintViolation(_:)`` (`.primaryKey`) if a vault already exists.
    public func createVault(_ vault: VaultRecord, keyWraps: [KeyWrapRecord]) throws {
        try database.write { tx in
            try insertVault(vault, in: tx)
            for wrap in keyWraps {
                try saveKeyWrap(wrap, in: tx)
            }
        }
        try database.checkpointTruncate()
    }

    public func insertVault(_ vault: VaultRecord, in tx: StoreTransaction) throws {
        try vault.insert(tx.db)
    }

    /// Replaces the vault row, then checkpoints. Throws ``StoreError/notFound`` if there is none.
    public func updateVault(_ vault: VaultRecord) throws {
        try database.write { try updateVault(vault, in: $0) }
        try database.checkpointTruncate()
    }

    public func updateVault(_ vault: VaultRecord, in tx: StoreTransaction) throws {
        do {
            try vault.update(tx.db)
        } catch is RecordError {
            throw StoreError.notFound
        }
    }

    // MARK: - key_wraps

    public func fetchKeyWrap(_ method: KeyWrapMethod) throws -> KeyWrapRecord? {
        try database.read { try fetchKeyWrap(method, in: $0) }
    }

    public func fetchKeyWrap(_ method: KeyWrapMethod, in tx: StoreTransaction) throws -> KeyWrapRecord? {
        try KeyWrapRecord.fetchOne(tx.db, key: method.rawValue)
    }

    /// Every wrap, ordered by method.
    public func fetchKeyWraps() throws -> [KeyWrapRecord] {
        try database.read { tx in
            try KeyWrapRecord.order(KeyWrapRecord.CodingKeys.method).fetchAll(tx.db)
        }
    }

    /// Inserts or replaces the wrap for its method, then checkpoints.
    public func saveKeyWrap(_ wrap: KeyWrapRecord) throws {
        try database.write { try saveKeyWrap(wrap, in: $0) }
        try database.checkpointTruncate()
    }

    public func saveKeyWrap(_ wrap: KeyWrapRecord, in tx: StoreTransaction) throws {
        try wrap.upsert(tx.db)
    }

    /// Deletes the wrap for `method`, then checkpoints. Returns false if there was none.
    @discardableResult
    public func deleteKeyWrap(_ method: KeyWrapMethod) throws -> Bool {
        let deleted = try database.write { try deleteKeyWrap(method, in: $0) }
        try database.checkpointTruncate()
        return deleted
    }

    @discardableResult
    public func deleteKeyWrap(_ method: KeyWrapMethod, in tx: StoreTransaction) throws -> Bool {
        try KeyWrapRecord.deleteOne(tx.db, key: method.rawValue)
    }

    // MARK: - Reset

    /// Deletes every row of every table in one transaction (vault reset), then checkpoints.
    /// `secure_delete` overwrites the freed pages; the schema and migrations stay.
    public func eraseAllData() throws {
        try database.write { try eraseAllData(in: $0) }
        try database.checkpointTruncate()
    }

    /// Deletes children before parents so foreign keys never block the reset.
    public func eraseAllData(in tx: StoreTransaction) throws {
        let tables = [
            SyncJournalRecord.databaseTableName,
            ImportedSharePackageRecord.databaseTableName,
            BranchPatternRecord.databaseTableName,
            ConfigItemRecord.databaseTableName,
            EnvironmentRecord.databaseTableName,
            RepositoryRecord.databaseTableName,
            AccountRecord.databaseTableName,
            KeyWrapRecord.databaseTableName,
            VaultRecord.databaseTableName,
        ]
        for table in tables {
            try tx.db.execute(sql: "DELETE FROM \(table)")
        }
    }
}
