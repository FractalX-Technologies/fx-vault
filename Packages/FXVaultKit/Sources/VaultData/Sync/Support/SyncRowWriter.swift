import Foundation
import VaultCore
import VaultCrypto
import VaultStore

/// Row bookkeeping shared by the sync effects (`SyncStateEffectModel`), the drift resolutions
/// (`DriftEffectModel`) and the repository import (`RepoImportWriter`, listed items), inside the
/// caller's transaction (§7.3, §7.6, §7.7).
///
/// A missing row is not an error: the user may have removed a repository, environment or item
/// while a run or a drift review was open, and its bookkeeping no longer matters. This matches
/// SyncEngine's reference fake (`InMemorySyncVault`).
struct SyncRowWriter {
    let database: VaultDatabase
    let tx: StoreTransaction
    let now: Date

    var config: ConfigStore {
        ConfigStore(database: database)
    }

    var repositories: RepoStore {
        RepoStore(database: database)
    }

    // MARK: - Updates

    /// Rewrites one item row with `body`. Returns false when there is no such row.
    @discardableResult
    func updateItem(_ id: ConfigItemID, _ body: (inout ConfigItemRecord) throws -> Void) throws -> Bool {
        guard var record = try config.fetchItemRecord(id: id, in: tx) else { return false }
        try body(&record)
        try config.updateItem(record, in: tx)
        return true
    }

    /// Rewrites one environment row (its pattern rows are separate). Returns false when there is
    /// no such row.
    @discardableResult
    func updateEnvironment(_ id: EnvironmentID, _ body: (inout EnvironmentModel) throws -> Void) throws -> Bool {
        guard var environment = try config.fetchEnvironment(id: id, in: tx) else { return false }
        try body(&environment)
        try config.updateEnvironment(environment, in: tx)
        return true
    }

    /// Rewrites one repository row. Returns false when there is no such row.
    @discardableResult
    func updateRepository(_ id: RepoID, _ body: (inout RepoModel) throws -> Void) throws -> Bool {
        guard var repository = try repositories.fetch(id: id, in: tx) else { return false }
        try body(&repository)
        try repositories.update(repository, in: tx)
        return true
    }

    // MARK: - Patterns

    /// The policy left custom on GitHub (§7.3 step 2): every pattern's `github_policy_id :=
    /// NULL` and pattern tombstones are removed.
    func unsyncPatterns(of environmentID: EnvironmentID) throws {
        for pattern in try config.fetchPatterns(environmentID: environmentID, in: tx) {
            if pattern.isDeleted {
                try config.deletePattern(id: pattern.id, in: tx)
            } else if pattern.githubPolicyID != nil {
                var unsynced = pattern
                unsynced.githubPolicyID = nil
                try config.updatePattern(unsynced, in: tx)
            }
        }
    }

    // MARK: - Detached remote identity (§7.6 step 6)

    /// Inserts a new tombstone row that takes over `record`'s current remote identity under
    /// `name` (the synced name a rename moves away from), so the old name is still deleted on
    /// GitHub by a later Sync.
    ///
    /// The tombstone keeps `record`'s synced value and `remote_updated_at`. Every blob is
    /// re-sealed for the new row and every fingerprint recomputed for its id (both are bound to
    /// the row). A variable row always holds a value (schema), so a variable tombstone stores
    /// the synced value, or the current value when no synced copy exists.
    ///
    /// Nothing is inserted when another row of the same scope and kind already uses `name`: that
    /// row owns the remote name now.
    ///
    /// Call it **before** changing `record`'s synced columns: they are read from it.
    func insertDetachedTombstone(of record: ConfigItemRecord, name: String, keys: borrowing UnlockedKeys) throws {
        let key = GitHubNameValidator.foldKey(name)
        let siblings = try config.fetchItemRecords(repositoryID: record.repositoryID, scope: record.scope, in: tx)
        let isTaken = siblings.contains { sibling in
            sibling.id != record.id && sibling.kind == record.kind && GitHubNameValidator.foldKey(sibling.name) == key
        }
        guard !isTaken else { return }
        var tombstone = ConfigItemRecord(
            repositoryID: record.repositoryID,
            scope: record.scope,
            kind: record.kind,
            name: name,
            valueCiphertext: nil,
            valueFingerprint: nil,
            isDeleted: true,
            syncedName: name,
            remoteUpdatedAt: record.remoteUpdatedAt,
            provenance: record.provenance,
            shareOrigin: record.shareOrigin,
            createdAt: now,
            updatedAt: now
        )
        let synced = try ConfigFieldCipher.openSyncedValue(of: record, keys: keys)
        defer { synced?.wipe() }
        if let synced {
            try ConfigFieldCipher.setSyncedValue(synced, on: &tombstone, keys: keys)
        }
        if record.kind == .variable {
            let value = try synced?.copy() ?? ConfigFieldCipher.openValue(of: record, keys: keys)
            guard let value else { throw SyncRowWriterError.variableWithoutValue }
            defer { value.wipe() }
            try ConfigFieldCipher.setValue(value, on: &tombstone, keys: keys)
        }
        try config.insertItem(tombstone, in: tx)
    }

    // MARK: - Items from a GitHub listing

    /// A new row for an item GitHub lists (drift "Accept GitHub" / "Keep local", §7.7):
    /// `synced_name := name`, `remote_updated_at` as listed, verified, `provenance = github`.
    /// A variable gets the listed value as its value and synced value (stored as listed, D32);
    /// a secret is value-missing (§7.8).
    ///
    /// - Parameters:
    ///   - listedValue: the listed variable value (required for a variable, ignored for a
    ///     secret). The caller wipes it.
    ///   - isTombstone: insert it pending deletion on GitHub instead ("Keep local" for a
    ///     remote-only item).
    @discardableResult
    func insertListedItem(
        repositoryID: RepoID,
        scope: ConfigScope,
        kind: ConfigKind,
        name: String,
        remoteUpdatedAt: Date?,
        listedValue: SecretBytes?,
        isTombstone: Bool,
        keys: borrowing UnlockedKeys
    ) throws -> ConfigItemID {
        var record = ConfigItemRecord(
            repositoryID: repositoryID,
            scope: scope,
            kind: kind,
            name: name,
            valueCiphertext: nil,
            valueFingerprint: nil,
            isDeleted: isTombstone,
            syncedName: name,
            remoteUpdatedAt: remoteUpdatedAt,
            provenance: .github,
            createdAt: now,
            updatedAt: now
        )
        if kind == .variable {
            guard let listedValue else { throw SyncRowWriterError.variableWithoutValue }
            try ConfigFieldCipher.setValue(listedValue, on: &record, keys: keys)
            try ConfigFieldCipher.setSyncedValue(listedValue, on: &record, keys: keys)
        }
        try config.insertItem(record, in: tx)
        return record.id
    }
}

/// A row the schema cannot hold.
enum SyncRowWriterError: Error, Sendable, Hashable {
    /// A variable row needs a value (`CHECK (kind = 'secret' OR value_ct IS NOT NULL)`).
    case variableWithoutValue
}
