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
    /// Secret fields re-encrypted: this device's teammate keys and teammates' announce keys
    /// (v0.5.0), and shared space keys (v0.6.0).
    var secretFields = 0
    /// Folder item values re-encrypted (and their fingerprints recomputed), v0.7.0.
    var folderValues = 0
    /// Destination item values re-encrypted (and their fingerprints recomputed), v0.8.0.
    var destinationValues = 0
    /// Destination `synced_fp` values that could not be recomputed and were cleared (the item is
    /// pushed again on the next Sync), v0.8.0.
    var destinationSyncedFingerprintsCleared = 0
    /// Supabase change markers re-keyed under the new `K_fp` (the others stay and show as a
    /// change at the next Refresh), v0.8.0.
    var destinationMarkersRekeyed = 0
    /// Provider connection tokens re-encrypted, v0.8.0.
    var connectionTokens = 0
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
/// Then `device_identity.secret_ct`, every `teammates.announce_ct` (v0.5.0), every
/// `space_keys.key_ct` (v0.6.0) and every `folder_items.value_ct` (v0.7.0, with `value_fp`
/// recomputed) are opened under the old keys and sealed under the new ones.
///
/// Any decryption failure aborts the whole transaction: a rotation never leaves rows under two
/// different DEKs.
struct DEKRotator {
    let repoStore: RepoStore
    let configStore: ConfigStore
    let teamStore: TeamStore
    let spaceStore: SpaceStore
    let folderStore: FolderStore
    let destinationStore: DestinationStore

    init(database: VaultDatabase) {
        repoStore = RepoStore(database: database)
        configStore = ConfigStore(database: database)
        teamStore = TeamStore(database: database)
        spaceStore = SpaceStore(database: database)
        folderStore = FolderStore(database: database)
        destinationStore = DestinationStore(database: database)
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
        if var identity = try teamStore.fetchIdentity(in: tx), let deviceID = TeamDeviceID(hex: identity.deviceID) {
            let aad = TeamRepository.identityAAD(deviceID: deviceID)
            identity.secretCiphertext = try reseal(identity.secretCiphertext, for: aad, from: oldKeys, to: newKeys)
            try teamStore.saveIdentity(identity, in: tx)
            report.secretFields += 1
        }
        for var teammate in try teamStore.fetchTeammates(in: tx) {
            guard let deviceID = TeamDeviceID(hex: teammate.deviceID) else { throw VaultError.corrupted(.invalidStoredValue) }
            let aad = TeamRepository.announceAAD(deviceID: deviceID)
            teammate.announceCiphertext = try reseal(teammate.announceCiphertext, for: aad, from: oldKeys, to: newKeys)
            try teamStore.saveTeammate(teammate, in: tx)
            report.secretFields += 1
        }
        for var key in try spaceStore.fetchAllKeys(in: tx) {
            let aad = SpaceRepository.keyAAD(spaceID: key.spaceID, epoch: key.epoch)
            key.keyCiphertext = try reseal(key.keyCiphertext, for: aad, from: oldKeys, to: newKeys)
            try spaceStore.saveKey(key, in: tx)
            report.secretFields += 1
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
        return report
    }

    /// Destination item values (with their fingerprints) and provider connection tokens (v0.8.0).
    /// A `synced_fp` is recomputed from the value when the two matched under the old key and
    /// cleared otherwise, as for repository items without `synced_value_ct`. A Supabase change
    /// marker is keyed under `K_fp` (`DestinationFieldCipher.keyedMarker`): it is re-keyed when
    /// the value's digest gives the stored marker under the old key, and kept otherwise (it then
    /// differs from every listing, which Refresh reports as a change: the safe direction).
    private func reencryptDestinations(
        from oldKeys: borrowing UnlockedKeys,
        to newKeys: borrowing UnlockedKeys,
        report: inout DEKRotationReportModel,
        in tx: StoreTransaction
    ) throws {
        for destination in try destinationStore.fetchAllDestinationRecords(in: tx) {
            for var item in try destinationStore.fetchItemRecords(destinationID: destination.id, in: tx) {
                guard let ciphertext = item.valueCiphertext else {
                    if item.syncedFingerprint != nil {
                        item.syncedFingerprint = nil
                        report.destinationSyncedFingerprintsCleared += 1
                        try destinationStore.updateItem(item, in: tx)
                    }
                    continue
                }
                let aad = DestinationFieldCipher.valueAAD(of: item)
                let plaintext = try oldKeys.open(ciphertext, for: aad)
                defer { plaintext.wipe() }
                if destination.provider == .supabase, let marker = item.remoteVersion {
                    let digest = DestinationFieldCipher.supabaseDigest(of: plaintext)
                    let remoteName = DestinationRules.remoteName(for: item.syncedName ?? item.name, provider: .supabase)
                    let old = DestinationFieldCipher.keyedMarker(digest: digest, remoteName: remoteName, destinationID: destination.id, keys: oldKeys)
                    if old == marker {
                        item.remoteVersion = DestinationFieldCipher.keyedMarker(
                            digest: digest,
                            remoteName: remoteName,
                            destinationID: destination.id,
                            keys: newKeys
                        )
                        report.destinationMarkersRekeyed += 1
                    }
                }
                if let synced = item.syncedFingerprint {
                    if oldKeys.fingerprintMatches(synced, value: plaintext, rowID: item.id) {
                        item.syncedFingerprint = newKeys.fingerprint(plaintext, rowID: item.id)
                    } else {
                        item.syncedFingerprint = nil
                        report.destinationSyncedFingerprintsCleared += 1
                    }
                }
                item.valueCiphertext = try newKeys.seal(plaintext, for: aad)
                item.valueFingerprint = newKeys.fingerprint(plaintext, rowID: item.id)
                try destinationStore.updateItem(item, in: tx)
                report.destinationValues += 1
            }
        }
        for var connection in try destinationStore.fetchConnectionRecords(in: tx) {
            connection.tokenCiphertext = try reseal(
                connection.tokenCiphertext,
                for: ConnectionTokenCipher.aad(of: connection.id),
                from: oldKeys,
                to: newKeys
            )
            try destinationStore.updateConnection(connection, in: tx)
            report.connectionTokens += 1
        }
    }

    private func reseal(
        _ blob: Data,
        for aad: SecretFieldAAD,
        from oldKeys: borrowing UnlockedKeys,
        to newKeys: borrowing UnlockedKeys
    ) throws -> Data {
        let plaintext = try oldKeys.open(blob, for: aad)
        defer { plaintext.wipe() }
        return try newKeys.seal(plaintext, for: aad)
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
