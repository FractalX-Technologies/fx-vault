import Foundation
import VaultCore
import VaultCrypto
import VaultStore

/// Counts from one DEK rotation, for the log. Never carries names or values.
struct DEKRotationReportModel: Sendable, Hashable {
    /// `value_ct` blobs re-encrypted (and `value_fp` recomputed).
    var values = 0
    /// `synced_value_ct` blobs re-encrypted (and `synced_fp` recomputed).
    var syncedValues = 0
    /// `synced_fp` values recomputed from the current value they equal (no `synced_value_ct`).
    var syncedFingerprintsFromValue = 0
    /// `synced_fp` values that could not be recomputed (no plaintext available) and were cleared,
    /// so the item shows as modified and is pushed again on the next sync.
    var syncedFingerprintsCleared = 0
}

/// Re-encrypts every encrypted column under a new DEK inside the caller's transaction (§5.2
/// `rotateDEK`, steps 2–3).
///
/// For each `config_items` row:
/// - `value_ct` is opened under the old keys and sealed under the new ones (the AAD carries the
///   DEK version), and `value_fp` is recomputed under the new `K_fp`;
/// - `synced_value_ct` likewise, with `synced_fp` recomputed from it;
/// - a `synced_fp` without `synced_value_ct` is recomputed from the current value when the two
///   matched under the old key, otherwise cleared (see ``DEKRotationReportModel``).
///
/// Any decryption failure aborts the whole transaction: a rotation never leaves rows under two
/// different DEKs.
struct DEKRotator {
    let repoStore: RepoStore
    let configStore: ConfigStore

    init(database: VaultDatabase) {
        repoStore = RepoStore(database: database)
        configStore = ConfigStore(database: database)
    }

    func reencryptAll(
        from oldKeys: borrowing UnlockedKeys,
        to newKeys: borrowing UnlockedKeys,
        in tx: StoreTransaction
    ) throws -> DEKRotationReportModel {
        var report = DEKRotationReportModel()
        for repo in try repoStore.fetchAll(in: tx) {
            for var record in try configStore.fetchItemRecords(repositoryID: repo.id, in: tx) {
                try reencrypt(&record, from: oldKeys, to: newKeys, report: &report)
                try configStore.updateItem(record, in: tx)
            }
        }
        return report
    }

    // MARK: - Private

    private func reencrypt(
        _ record: inout ConfigItemRecord,
        from oldKeys: borrowing UnlockedKeys,
        to newKeys: borrowing UnlockedKeys,
        report: inout DEKRotationReportModel
    ) throws {
        var value: SecretBytes?
        defer { value?.wipe() }

        if let ciphertext = record.valueCiphertext {
            let aad = Self.aad(of: record, location: .configItemValue, name: record.name)
            let plaintext = try oldKeys.open(ciphertext, for: aad)
            value = plaintext
            record.valueCiphertext = try newKeys.seal(plaintext, for: aad)
            record.valueFingerprint = newKeys.fingerprint(plaintext, rowID: record.id)
            report.values += 1
        }

        if let syncedCiphertext = record.syncedValueCiphertext {
            guard let syncedName = record.syncedName else { throw VaultError.corrupted(.invalidStoredValue) }
            let aad = Self.aad(of: record, location: .configItemSyncedValue, name: syncedName)
            let synced = try oldKeys.open(syncedCiphertext, for: aad)
            defer { synced.wipe() }
            record.syncedValueCiphertext = try newKeys.seal(synced, for: aad)
            if record.syncedFingerprint != nil {
                record.syncedFingerprint = newKeys.fingerprint(synced, rowID: record.id)
            }
            report.syncedValues += 1
        } else if let syncedFingerprint = record.syncedFingerprint {
            if let value, oldKeys.fingerprintMatches(syncedFingerprint, value: value, rowID: record.id) {
                record.syncedFingerprint = newKeys.fingerprint(value, rowID: record.id)
                report.syncedFingerprintsFromValue += 1
            } else {
                record.syncedFingerprint = nil
                report.syncedFingerprintsCleared += 1
            }
        }
    }

    /// The field AAD of one encrypted column of `record` (§5.4).
    private static func aad(of record: ConfigItemRecord, location: FieldLocation, name: String) -> FieldAAD {
        FieldAAD(
            location: location,
            rowID: record.id,
            repositoryID: record.repositoryID,
            environmentID: record.environmentID,
            kind: record.kind,
            name: name
        )
    }
}
