import Foundation
import SyncEngine
import VaultCore
import VaultCrypto
import VaultStore

/// Writes the row mutations of one `ConfigItemEditPlanner` edit inside the caller's transaction
/// (§7.1 editing rules, §5.4).
///
/// For each mutation it rebuilds the `config_items` record from the planner's snapshot row and
/// produces the ciphertexts:
/// - the local value comes from ``ItemValueSourceModel``: the new value, the row's own synced
///   value (Revert), another row's value (tombstone revival, Convert/Move) or the stored one;
/// - whenever the row's name, scope or kind differs from the stored row, the stored value is
///   re-sealed, because the field AAD binds them;
/// - `value_fp` is recomputed for the target row id from the plaintext it seals;
/// - a row that takes over another row's item (Convert/Move, a rename or move into a tombstone)
///   takes over its `link_id` too (v0.4.1); every other edit keeps the stored link;
/// - `share_hold` (v0.9.0) follows the item the same way, so moving or renaming a held row keeps
///   it held (the value is still the share file's), and is cleared when the row is deleted,
///   reverted or given a new value: those are the user's own changes, never a share file's.
///
/// Every plaintext is wiped before the method returns.
struct ItemMutationWriter {
    let store: ConfigStore
    let repositoryID: RepoID
    let now: Date

    /// Applies `mutations` in order. `newValue` is the edit's value (normalized), when it has one.
    func apply(
        _ mutations: [ItemMutationModel],
        newValue: SecretBytes?,
        keys: borrowing UnlockedKeys,
        in tx: StoreTransaction
    ) throws {
        let before = try recordsBeforeEdit(mutations, in: tx)
        for mutation in mutations {
            switch mutation {
            case .insert(let row, let source):
                var record = newRecord(for: row, shareOrigin: shareOrigin(of: source, before: before))
                if let link = movedLink(of: source, before: before) {
                    record.linkID = link
                }
                record.shareHold = Self.shareHold(row: row, source: source, kept: nil, before: before)
                try fill(&record, row: row, source: source, stored: nil, before: before, newValue: newValue, keys: keys)
                try store.insertItem(record, in: tx)
            case .update(let row, let source):
                guard let stored = before[row.id] else { throw ConfigRepositoryError.itemNotFound }
                var record = stored
                apply(row, to: &record)
                if let link = movedLink(of: source, before: before) {
                    record.linkID = link
                }
                record.shareHold = Self.shareHold(row: row, source: source, kept: stored.shareHold, before: before)
                try fill(&record, row: row, source: source, stored: stored, before: before, newValue: newValue, keys: keys)
                try store.updateItem(record, in: tx)
            case .remove(let id):
                try store.deleteItem(id: id, in: tx)
            }
        }
    }

    // MARK: - Records

    /// The stored rows every mutation refers to (targets and value sources), read before any
    /// of them is written: a value source may itself be retired later in the same edit.
    private func recordsBeforeEdit(
        _ mutations: [ItemMutationModel],
        in tx: StoreTransaction
    ) throws -> [ConfigItemID: ConfigItemRecord] {
        var ids: Set<ConfigItemID> = []
        for mutation in mutations {
            switch mutation {
            case .insert(_, let source), .update(_, let source):
                if case .movedFrom(let sourceID) = source { ids.insert(sourceID) }
                if case .update(let row, _) = mutation { ids.insert(row.id) }
            case .remove:
                break
            }
        }
        var records: [ConfigItemID: ConfigItemRecord] = [:]
        for id in ids {
            records[id] = try store.fetchItemRecord(id: id, in: tx)
        }
        return records
    }

    private func newRecord(for row: ConfigItemSnapshotModel, shareOrigin: ShareOriginModel?) -> ConfigItemRecord {
        ConfigItemRecord(
            id: row.id,
            repositoryID: repositoryID,
            scope: row.scope,
            kind: row.kind,
            name: row.name,
            valueCiphertext: nil,
            valueFingerprint: nil,
            isDeleted: row.isDeleted,
            syncedName: row.syncedName,
            forcePush: row.forcePush,
            forcePushRequestedAt: row.forcePushRequestedAt,
            remoteUpdatedAt: row.remoteUpdatedAt,
            verifyState: row.verifyState,
            preWriteUpdatedAt: row.preWriteUpdatedAt,
            provenance: row.provenance,
            shareOrigin: row.provenance == .share ? shareOrigin : nil,
            createdAt: now,
            updatedAt: now
        )
    }

    /// Copies the snapshot's non-value columns onto a stored record.
    private func apply(_ row: ConfigItemSnapshotModel, to record: inout ConfigItemRecord) {
        record.scope = row.scope
        record.kind = row.kind
        record.name = row.name
        record.isDeleted = row.isDeleted
        record.syncedName = row.syncedName
        record.syncedFingerprint = row.syncedFingerprint
        record.forcePush = row.forcePush
        record.forcePushRequestedAt = row.forcePushRequestedAt
        record.remoteUpdatedAt = row.remoteUpdatedAt
        record.verifyState = row.verifyState
        record.preWriteUpdatedAt = row.preWriteUpdatedAt
        if record.provenance != row.provenance {
            record.provenance = row.provenance
            record.shareOrigin = row.provenance == .share ? record.shareOrigin : nil
        }
        record.updatedAt = now
    }

    /// The row's `share_hold` after the edit: the moved item's hold for a move, none for a
    /// deletion, a Revert or a value the user typed, otherwise `kept`.
    private static func shareHold(
        row: ConfigItemSnapshotModel,
        source: ItemValueSourceModel,
        kept: SharePackageID?,
        before: [ConfigItemID: ConfigItemRecord]
    ) -> SharePackageID? {
        if row.isDeleted { return nil }
        switch source {
        case .movedFrom(let sourceID): return before[sourceID]?.shareHold
        case .syncedValue, .newValue: return nil
        case .unchanged, .newValueAsSynced: return kept
        }
    }

    /// The link of the row an item moves from: `.some(link)` (possibly nil) for a move, `nil`
    /// when the item does not move.
    private func movedLink(
        of source: ItemValueSourceModel,
        before: [ConfigItemID: ConfigItemRecord]
    ) -> ItemLinkID?? {
        guard case .movedFrom(let sourceID) = source else { return nil }
        return .some(before[sourceID]?.linkID)
    }

    private func shareOrigin(
        of source: ItemValueSourceModel,
        before: [ConfigItemID: ConfigItemRecord]
    ) -> ShareOriginModel? {
        guard case .movedFrom(let sourceID) = source else { return nil }
        return before[sourceID]?.shareOrigin
    }

    // MARK: - Values

    /// Sets `value_ct`/`value_fp` and the synced columns of `record` for `source`.
    private func fill(
        _ record: inout ConfigItemRecord,
        row: ConfigItemSnapshotModel,
        source: ItemValueSourceModel,
        stored: ConfigItemRecord?,
        before: [ConfigItemID: ConfigItemRecord],
        newValue: SecretBytes?,
        keys: borrowing UnlockedKeys
    ) throws {
        // Local value.
        let plaintext = try localPlaintext(
            for: source,
            record: record,
            stored: stored,
            before: before,
            newValue: newValue,
            keys: keys
        )
        if let plaintext {
            defer { plaintext.wipe() }
            try ConfigFieldCipher.setValue(plaintext, on: &record, keys: keys)
        } else if !Self.keepsStoredValue(source: source, record: record, stored: stored) {
            record.valueCiphertext = nil
            record.valueFingerprint = nil
        }

        // Synced value.
        if source == .newValueAsSynced {
            guard let newValue else { throw ConfigRepositoryError.unexpected }
            try ConfigFieldCipher.setSyncedValue(newValue, on: &record, keys: keys)
        } else if !row.hasSyncedValue {
            record.syncedValueCiphertext = nil
        } else if let stored, let storedAAD = ConfigFieldCipher.syncedAAD(of: stored),
                  storedAAD != ConfigFieldCipher.syncedAAD(of: record),
                  let synced = try ConfigFieldCipher.openSyncedValue(of: stored, keys: keys) {
            defer { synced.wipe() }
            let fingerprint = record.syncedFingerprint
            try ConfigFieldCipher.setSyncedValue(synced, on: &record, keys: keys)
            record.syncedFingerprint = fingerprint
        }
    }

    /// The plaintext to seal as the local value, or nil when the stored value is kept as is or
    /// there is no value.
    private func localPlaintext(
        for source: ItemValueSourceModel,
        record: ConfigItemRecord,
        stored: ConfigItemRecord?,
        before: [ConfigItemID: ConfigItemRecord],
        newValue: SecretBytes?,
        keys: borrowing UnlockedKeys
    ) throws -> SecretBytes? {
        switch source {
        case .newValue, .newValueAsSynced:
            guard let newValue else { throw ConfigRepositoryError.unexpected }
            return newValue.copy()
        case .syncedValue:
            guard let stored else { return nil }
            return try ConfigFieldCipher.openSyncedValue(of: stored, keys: keys)
        case .movedFrom(let sourceID):
            guard let origin = before[sourceID] else { throw ConfigRepositoryError.itemNotFound }
            return try ConfigFieldCipher.openValue(of: origin, keys: keys)
        case .unchanged:
            guard let stored, !Self.keepsStoredValue(source: source, record: record, stored: stored) else { return nil }
            return try ConfigFieldCipher.openValue(of: stored, keys: keys)
        }
    }

    /// True when the stored `value_ct` stays valid: the value is unchanged and the row's
    /// identity (the AAD) did not move.
    private static func keepsStoredValue(
        source: ItemValueSourceModel,
        record: ConfigItemRecord,
        stored: ConfigItemRecord?
    ) -> Bool {
        guard source == .unchanged, let stored else { return false }
        return ConfigFieldCipher.valueAAD(of: stored) == ConfigFieldCipher.valueAAD(of: record)
    }
}
