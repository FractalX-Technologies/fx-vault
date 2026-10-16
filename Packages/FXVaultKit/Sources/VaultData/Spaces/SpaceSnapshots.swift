import Foundation
import SharingKit
import VaultCore
import VaultCrypto
import VaultStore

/// The key of an item inside a scope: its kind and GitHub fold key.
struct SpaceItemKey: Hashable {
    let kind: ConfigKind
    let nameKey: String

    init(kind: ConfigKind, name: String) {
        self.kind = kind
        nameKey = GitHubNameValidator.foldKey(name)
    }
}

/// The scope as GitHub holds it, from this Mac's rows (S3): every row GitHub has (a synced
/// name, tombstones included) with its last pushed value and GitHub's `updatedAt`.
///
/// - A row whose last push is not verified yet keeps the previous version's entry (GitHub may
///   still hold the old value), or is left out when there is none.
/// - A value this Mac does not know comes from the previous version when GitHub still has the
///   same `updatedAt`; otherwise the item has no value (only genesis refuses that).
/// - Rows never pushed are not on GitHub and are left out.
enum SpaceSnapshotBuilder {
    static func snapshot(
        of rows: [ConfigItemRecord],
        previous: SpaceSnapshotModel?,
        reason: String,
        keys: borrowing UnlockedKeys
    ) throws -> SpaceSnapshotModel {
        let earlier = Dictionary(
            (previous?.items ?? []).map { (SpaceItemKey(kind: $0.kind, name: $0.name), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var items: [SpaceItemModel] = []
        for row in rows {
            guard let syncedName = row.syncedName else { continue }
            let key = SpaceItemKey(kind: row.kind, name: syncedName)
            guard row.verifyState == .verified else {
                if let kept = earlier[key] {
                    items.append(SpaceItemModel(kind: kept.kind, name: kept.name, value: kept.value?.copy(), githubUpdatedAt: kept.githubUpdatedAt))
                }
                continue
            }
            var value = try pushedValue(of: row, keys: keys)
            if value == nil, let kept = earlier[key], kept.githubUpdatedAt == row.remoteUpdatedAt {
                value = kept.value?.copy()
            }
            items.append(SpaceItemModel(kind: row.kind, name: syncedName, value: value, githubUpdatedAt: row.remoteUpdatedAt))
        }
        return SpaceSnapshotModel(reason: reason, items: items)
    }

    /// The value GitHub received last: `synced_value_ct`, or the local value when it is the
    /// pushed one (same fingerprint). The caller wipes it.
    static func pushedValue(of row: ConfigItemRecord, keys: borrowing UnlockedKeys) throws -> SecretBytes? {
        if let synced = try ConfigFieldCipher.openSyncedValue(of: row, keys: keys) {
            return synced
        }
        guard let fingerprint = row.syncedFingerprint, fingerprint == row.valueFingerprint else { return nil }
        return try ConfigFieldCipher.openValue(of: row, keys: keys)
    }

    /// True when both snapshots hold the same items, values and GitHub dates (the reason aside).
    static func sameItems(_ lhs: SpaceSnapshotModel, _ rhs: SpaceSnapshotModel) -> Bool {
        guard lhs.items.count == rhs.items.count else { return false }
        let others = Dictionary(rhs.items.map { (SpaceItemKey(kind: $0.kind, name: $0.name), $0) }, uniquingKeysWith: { first, _ in first })
        return lhs.items.allSatisfy { item in
            guard let other = others[SpaceItemKey(kind: item.kind, name: item.name)] else { return false }
            return other.name == item.name && other.githubUpdatedAt == item.githubUpdatedAt && sameValue(item.value, other.value)
        }
    }

    static func sameValue(_ lhs: SecretBytes?, _ rhs: SecretBytes?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case (let lhs?, let rhs?):
            lhs.withUnsafeBytes { left in rhs.withUnsafeBytes { right in left.elementsEqual(right) } }
        default:
            false
        }
    }
}

/// Applies a teammate's version to the vault rows of its scope in the caller's transaction (S8).
///
/// For each item of the snapshot (what GitHub now holds):
/// - a row GitHub knows under that name with no local edit takes the value (sealed for the row)
///   as both its value and its synced value, and GitHub's `updatedAt`;
/// - a row with a local edit keeps it as a draft and only moves its synced baseline, so the next
///   Sync pushes the edit on top (Keep Mine); it is reported as a conflict when the teammate's
///   value differs from the old baseline;
/// - a never-pushed row with the same name takes the synced identity and keeps its value as a
///   pending change (reported);
/// - otherwise a new synced row is inserted.
///
/// A row GitHub knew that the snapshot no longer has (a teammate deleted it) is removed when it
/// has no local edit, and becomes a pending add of the local draft otherwise (reported).
struct SpaceSnapshotApplier {
    let rows: SyncRowWriter
    let keys: UnlockedKeys

    func apply(_ snapshot: SpaceSnapshotModel, repositoryID: RepoID, scope: ConfigScope) throws -> SpaceApplyResultModel {
        var result = SpaceApplyResultModel()
        let existing = try rows.config.fetchItemRecords(repositoryID: repositoryID, scope: scope, in: rows.tx)
        var bySyncedName: [SpaceItemKey: ConfigItemRecord] = [:]
        var byLocalName: [SpaceItemKey: ConfigItemRecord] = [:]
        for row in existing {
            if let syncedName = row.syncedName {
                bySyncedName[SpaceItemKey(kind: row.kind, name: syncedName)] = row
            }
            byLocalName[SpaceItemKey(kind: row.kind, name: row.name)] = row
        }
        var seen: Set<SpaceItemKey> = []
        for item in snapshot.items {
            let key = SpaceItemKey(kind: item.kind, name: item.name)
            seen.insert(key)
            let name = try GitHubNameValidator.validate(item.name)
            if let row = bySyncedName[key] {
                try update(row, with: item, result: &result)
            } else if let row = byLocalName[key] {
                try adopt(row, syncedName: name, item: item)
                result.conflictNames.append(row.name)
            } else {
                try insert(item, name: name, repositoryID: repositoryID, scope: scope)
                result.updated += 1
            }
        }
        for (key, row) in bySyncedName where !seen.contains(key) {
            if Self.isClean(row) || row.isDeleted {
                try rows.config.deleteItem(id: row.id, in: rows.tx)
                result.updated += 1
            } else {
                try rows.updateItem(row.id) { record in
                    record.markUnsynced()
                    record.updatedAt = rows.now
                }
                result.conflictNames.append(row.name)
            }
        }
        result.conflictNames.sort()
        return result
    }

    /// No local edit: same name, not deleted, no forced push, the local value is the synced one.
    static func isClean(_ row: ConfigItemRecord) -> Bool {
        row.name == row.syncedName && !row.isDeleted && !row.forcePush && row.valueFingerprint == row.syncedFingerprint
    }

    private func update(_ row: ConfigItemRecord, with item: SpaceItemModel, result: inout SpaceApplyResultModel) throws {
        var record = row
        let clean = Self.isClean(row)
        let previous = try SpaceSnapshotBuilder.pushedValue(of: row, keys: keys)
        defer { previous?.wipe() }
        let changed = !SpaceSnapshotBuilder.sameValue(previous, item.value) || row.remoteUpdatedAt != item.githubUpdatedAt
        if clean {
            if let value = item.value {
                try ConfigFieldCipher.setValue(value, on: &record, keys: keys)
                try ConfigFieldCipher.setSyncedValue(value, on: &record, keys: keys)
            } else if row.remoteUpdatedAt != item.githubUpdatedAt {
                // GitHub has a value this Mac cannot know: the secret is "value missing" now.
                record.clearValues()
            }
        } else {
            if let value = item.value {
                try ConfigFieldCipher.setSyncedValue(value, on: &record, keys: keys)
            } else {
                record.syncedValueCiphertext = nil
                record.syncedFingerprint = nil
            }
            if changed && !SpaceSnapshotBuilder.sameValue(previous, item.value) {
                result.conflictNames.append(row.name)
            }
        }
        record.remoteUpdatedAt = item.githubUpdatedAt
        record.verifyState = .verified
        record.preWriteUpdatedAt = nil
        if record.provenance == .share {
            record.provenance = .github
            record.shareOrigin = nil
        }
        guard record != row else { return }
        record.updatedAt = rows.now
        try rows.config.updateItem(record, in: rows.tx)
        if changed && clean { result.updated += 1 }
    }

    /// A never-pushed row with the teammate's name: it takes the synced identity and keeps its
    /// own value as a pending change.
    private func adopt(_ row: ConfigItemRecord, syncedName: String, item: SpaceItemModel) throws {
        var record = row
        record.syncedName = syncedName
        record.remoteUpdatedAt = item.githubUpdatedAt
        record.verifyState = .verified
        record.preWriteUpdatedAt = nil
        if let value = item.value {
            try ConfigFieldCipher.setSyncedValue(value, on: &record, keys: keys)
        } else {
            record.syncedValueCiphertext = nil
            record.syncedFingerprint = nil
            if record.kind == .secret { record.forcePush = true }
        }
        record.updatedAt = rows.now
        try rows.config.updateItem(record, in: rows.tx)
    }

    private func insert(_ item: SpaceItemModel, name: String, repositoryID: RepoID, scope: ConfigScope) throws {
        var record = ConfigItemRecord(
            repositoryID: repositoryID,
            scope: scope,
            kind: item.kind,
            name: name,
            valueCiphertext: nil,
            valueFingerprint: nil,
            syncedName: name,
            remoteUpdatedAt: item.githubUpdatedAt,
            provenance: .github,
            createdAt: rows.now,
            updatedAt: rows.now
        )
        if let value = item.value {
            try ConfigFieldCipher.setValue(value, on: &record, keys: keys)
            try ConfigFieldCipher.setSyncedValue(value, on: &record, keys: keys)
        } else if item.kind == .variable {
            throw SpaceRepositoryError.log(.malformed)
        }
        try rows.config.insertItem(record, in: rows.tx)
    }
}
