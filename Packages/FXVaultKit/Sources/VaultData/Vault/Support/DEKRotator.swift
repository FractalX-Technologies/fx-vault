import Foundation
import SharingKit
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
    /// Folder item values re-encrypted (and their fingerprints recomputed), v0.7.0.
    var folderValues = 0
    /// Destination item values re-encrypted (and their fingerprints recomputed), v0.8.0.
    var destinationValues = 0
    /// Destination `synced_fp` values that could not be recomputed and were cleared (the item is
    /// pushed again on the next Sync), v0.8.0.
    var destinationSyncedFingerprintsCleared = 0
    /// Organization item values re-encrypted (and their fingerprints recomputed), 1.0.
    var organizationValues = 0
    /// Organization `synced_fp` values that could not be recomputed and were cleared, 1.0.
    var organizationSyncedFingerprintsCleared = 0
    /// Folder files re-sealed (v23).
    var folderFiles = 0
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
/// Then every `folder_items.value_ct` (v0.7.0, with `value_fp` recomputed), `destination_items`
/// (v0.8.0) and `org_items` (1.0) value, and every folder file's bytes (v23), is opened under the
/// old keys and sealed under the new ones.
///
/// Any decryption failure aborts the whole transaction: a rotation never leaves rows under two
/// different DEKs.
struct DEKRotator {
    let repoStore: RepoStore
    let configStore: ConfigStore
    let folderStore: FolderStore
    let destinationStore: DestinationStore
    let organizationStore: OrganizationStore

    init(database: VaultDatabase) {
        repoStore = RepoStore(database: database)
        configStore = ConfigStore(database: database)
        folderStore = FolderStore(database: database)
        destinationStore = DestinationStore(database: database)
        organizationStore = OrganizationStore(database: database)
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
        for folder in try folderStore.fetchFolderRecords(in: tx) {
            for var item in try folderStore.fetchItemRecords(folderID: folder.id, in: tx) {
                let aad = FolderFieldCipher.valueAAD(of: item)
                let plaintext = try oldKeys.open(item.valueCiphertext, for: aad)
                defer { plaintext.wipe() }
                item.valueCiphertext = try newKeys.seal(plaintext, for: aad)
                item.valueFingerprint = newKeys.fingerprint(plaintext, rowID: item.id)
                try folderStore.updateItem(item, in: tx)
                report.folderValues += 1
            }
        }
        try reencryptDestinations(from: oldKeys, to: newKeys, report: &report, in: tx)
        try reencryptOrganizations(from: oldKeys, to: newKeys, report: &report, in: tx)
        try reencryptFolderFiles(from: oldKeys, to: newKeys, report: &report, in: tx)
        return report
    }

    /// Folder files (v23), one blob at a time so at most one file is in memory unsealed.
    private func reencryptFolderFiles(
        from oldKeys: borrowing UnlockedKeys,
        to newKeys: borrowing UnlockedKeys,
        report: inout DEKRotationReportModel,
        in tx: StoreTransaction
    ) throws {
        for id in try folderStore.fetchFileIDs(in: tx) {
            guard var blob = try folderStore.fetchFileBlob(fileID: id, in: tx) else { continue }
            let aad = FolderFileAAD(fileID: id)
            let plaintext = try oldKeys.open(blob.contentCiphertext, for: aad)
            defer { plaintext.wipe() }
            blob.contentCiphertext = try newKeys.seal(plaintext, for: aad)
            try folderStore.updateFileBlob(blob, in: tx)
            report.folderFiles += 1
        }
    }

    /// Destination item values with their fingerprints (v0.8.0). A `synced_fp` is recomputed
    /// from the value when the two matched under the old key and cleared otherwise, as for
    /// repository items without `synced_value_ct`.
    private func reencryptDestinations(
        from oldKeys: borrowing UnlockedKeys,
        to newKeys: borrowing UnlockedKeys,
        report: inout DEKRotationReportModel,
        in tx: StoreTransaction
    ) throws {
        for destination in try destinationStore.fetchAllDestinationRecords(in: tx) {
            for var item in try destinationStore.fetchItemRecords(destinationID: destination.id, in: tx) {
                let rotated = try rotate(
                    ciphertext: item.valueCiphertext,
                    syncedFingerprint: item.syncedFingerprint,
                    aad: DestinationFieldCipher.valueAAD(of: item),
                    rowID: item.id,
                    from: oldKeys,
                    to: newKeys
                )
                guard rotated.isChanged else { continue }
                item.valueCiphertext = rotated.ciphertext
                item.valueFingerprint = rotated.fingerprint ?? item.valueFingerprint
                item.syncedFingerprint = rotated.syncedFingerprint
                try destinationStore.updateItem(item, in: tx)
                if rotated.ciphertext != nil { report.destinationValues += 1 }
                if rotated.clearedSyncedFingerprint { report.destinationSyncedFingerprintsCleared += 1 }
            }
        }
    }

    /// Organization item values (1.0), with the same `synced_fp` rule as destinations.
    private func reencryptOrganizations(
        from oldKeys: borrowing UnlockedKeys,
        to newKeys: borrowing UnlockedKeys,
        report: inout DEKRotationReportModel,
        in tx: StoreTransaction
    ) throws {
        for organization in try organizationStore.fetchOrganizationRecords(in: tx) {
            for var item in try organizationStore.fetchItemRecords(organizationID: organization.id, in: tx) {
                let rotated = try rotate(
                    ciphertext: item.valueCiphertext,
                    syncedFingerprint: item.syncedFingerprint,
                    aad: OrgFieldCipher.valueAAD(of: item),
                    rowID: item.id,
                    from: oldKeys,
                    to: newKeys
                )
                guard rotated.isChanged else { continue }
                item.valueCiphertext = rotated.ciphertext
                item.valueFingerprint = rotated.fingerprint ?? item.valueFingerprint
                item.syncedFingerprint = rotated.syncedFingerprint
                try organizationStore.updateItem(item, in: tx)
                if rotated.ciphertext != nil { report.organizationValues += 1 }
                if rotated.clearedSyncedFingerprint { report.organizationSyncedFingerprintsCleared += 1 }
            }
        }
    }

    /// One value that may be missing (a secret GitHub never returned), with its `synced_fp`.
    private struct RotatedValue {
        var ciphertext: Data?
        var fingerprint: Data?
        var syncedFingerprint: Data?
        var clearedSyncedFingerprint = false

        /// False when the row has neither a value nor a `synced_fp`: nothing to rewrite.
        var isChanged: Bool {
            ciphertext != nil || clearedSyncedFingerprint
        }
    }

    /// Re-seals a value under the new keys. A `synced_fp` is recomputed from the value when the
    /// two matched under the old key and cleared otherwise (no value: always cleared), so the
    /// item is pushed again rather than compared under a stale key.
    private func rotate(
        ciphertext: Data?,
        syncedFingerprint: Data?,
        aad: some FieldContext,
        rowID: ConfigItemID,
        from oldKeys: borrowing UnlockedKeys,
        to newKeys: borrowing UnlockedKeys
    ) throws -> RotatedValue {
        guard let ciphertext else {
            return RotatedValue(clearedSyncedFingerprint: syncedFingerprint != nil)
        }
        let plaintext = try oldKeys.open(ciphertext, for: aad)
        defer { plaintext.wipe() }
        var rotated = RotatedValue(
            ciphertext: try newKeys.seal(plaintext, for: aad),
            fingerprint: newKeys.fingerprint(plaintext, rowID: rowID)
        )
        if let syncedFingerprint {
            if oldKeys.fingerprintMatches(syncedFingerprint, value: plaintext, rowID: rowID) {
                rotated.syncedFingerprint = newKeys.fingerprint(plaintext, rowID: rowID)
            } else {
                rotated.clearedSyncedFingerprint = true
            }
        }
        return rotated
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
