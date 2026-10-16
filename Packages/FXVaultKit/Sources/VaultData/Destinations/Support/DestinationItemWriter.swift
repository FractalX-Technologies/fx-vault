import Foundation
import VaultCore
import VaultCrypto
import VaultStore

/// Item writes of destinations inside one `VaultSession.write` transaction (v0.8.0), shared by
/// ``DestinationRepository``, copy and paste, linked copies, `.env` import and the destination
/// sync.
///
/// Edits stay local until the next Sync, as for repository items:
/// - A never-pushed row is changed or removed in place.
/// - Deleting a pushed row leaves a tombstone (`is_deleted`) that the Sync deletes remotely.
/// - Renaming a pushed row tombstones the old name and adds the new one (providers have no rename),
///   carrying the value and the link over.
/// - Adding a name held by a tombstone revives that row with the new value.
///
/// Names follow GitHub's rules plus the provider's (``DestinationRules``); Key Vault and Supabase
/// hold secrets only, so a variable written there becomes a secret. Values passed in must already
/// be normalized (D32).
struct DestinationItemWriter {
    private let store: DestinationStore
    private let keys: UnlockedKeys
    private let tx: StoreTransaction
    private let now: Date

    init(store: DestinationStore, keys: borrowing UnlockedKeys, tx: StoreTransaction, now: Date) {
        self.store = store
        self.keys = copy keys
        self.tx = tx
        self.now = now
    }

    /// The destination, or `.destinationNotFound`.
    func requireDestination(_ id: DestinationID) throws -> DestinationRecord {
        guard let destination = try store.fetchDestination(id: id, in: tx) else {
            throw ConfigRepositoryError.destinationNotFound
        }
        return destination
    }

    /// The item, or `.itemNotFound`.
    func existing(_ id: ConfigItemID) throws -> DestinationItemRecord {
        guard let record = try store.fetchItemRecord(id: id, in: tx) else {
            throw ConfigRepositoryError.itemNotFound
        }
        return record
    }

    /// The live (not deleted) row whose name folds like `name`, or nil.
    func liveRow(destinationID: DestinationID, name: String) throws -> DestinationItemRecord? {
        guard let record = try store.fetchItemRecord(destinationID: destinationID, name: name, in: tx), !record.isDeleted else {
            return nil
        }
        return record
    }

    /// Adds an item (or revives the tombstone holding its name). Returns the row's id.
    ///
    /// - Throws: `.validation` (an invalid name for the provider, a name the destination already
    ///   has, an oversized value), `.destinationFull`, `.destinationNotFound`.
    @discardableResult
    func add(
        destinationID: DestinationID,
        kind: ConfigKind,
        name: String,
        value: SecretBytes,
        linkID: ItemLinkID? = nil
    ) throws -> ConfigItemID {
        let destination = try requireDestination(destinationID)
        let storedKind = destination.provider.storedKind(for: kind)
        let validName = try DestinationRules.validate(name, kind: storedKind, provider: destination.provider)
        try requireSize(value, provider: destination.provider)
        if let current = try store.fetchItemRecord(destinationID: destinationID, name: validName, in: tx) {
            guard current.isDeleted else { throw ValidationError.duplicateName }
            var revived = current
            revived.isDeleted = false
            revived.kind = storedKind
            revived.name = validName
            revived.linkID = linkID ?? current.linkID
            revived.updatedAt = now
            try DestinationFieldCipher.setValue(value, on: &revived, keys: keys)
            try store.updateItem(revived, in: tx)
            try touch(destination)
            return revived.id
        }
        guard try store.countLiveItems(destinationID: destinationID, in: tx) < Limits.maxDestinationItems else {
            throw ConfigRepositoryError.destinationFull(limit: Limits.maxDestinationItems)
        }
        var record = DestinationItemRecord(
            destinationID: destinationID,
            kind: storedKind,
            name: validName,
            valueCiphertext: nil,
            valueFingerprint: nil,
            linkID: linkID,
            createdAt: now,
            updatedAt: now
        )
        try DestinationFieldCipher.setValue(value, on: &record, keys: keys)
        try store.insertItem(record, in: tx)
        try touch(destination)
        return record.id
    }

    /// Replaces an item's value.
    func editValue(_ id: ConfigItemID, value: SecretBytes) throws {
        var record = try existing(id)
        guard !record.isDeleted else { throw ConfigRepositoryError.itemNotFound }
        let destination = try requireDestination(record.destinationID)
        try requireSize(value, provider: destination.provider)
        try DestinationFieldCipher.setValue(value, on: &record, keys: keys)
        record.updatedAt = now
        try store.updateItem(record, in: tx)
        try touch(destination)
    }

    /// Fills a value the vault does not have (a write-only remote value). With
    /// `alreadyMatchesRemote` the value counts as what the remote holds, so nothing is pushed.
    func fill(_ id: ConfigItemID, value: SecretBytes, alreadyMatchesRemote: Bool) throws {
        try editValue(id, value: value)
        guard alreadyMatchesRemote else { return }
        var record = try existing(id)
        if record.isSynced {
            record.syncedFingerprint = record.valueFingerprint
            try store.updateItem(record, in: tx)
        }
    }

    /// Renames an item and, where the provider stores variables, changes its kind. Returns the
    /// row that holds the item afterwards (a new row when a pushed item was renamed).
    @discardableResult
    func update(_ id: ConfigItemID, name: String, kind: ConfigKind) throws -> ConfigItemID {
        let record = try existing(id)
        guard !record.isDeleted else { throw ConfigRepositoryError.itemNotFound }
        let destination = try requireDestination(record.destinationID)
        let storedKind = destination.provider.storedKind(for: kind)
        let validName = try DestinationRules.validate(name, kind: storedKind, provider: destination.provider)
        let isRename = GitHubNameValidator.foldKey(validName) != GitHubNameValidator.foldKey(record.name)
        guard isRename || validName != record.name || storedKind != record.kind else { return id }
        if isRename, let holder = try store.fetchItemRecord(destinationID: record.destinationID, name: validName, in: tx), !holder.isDeleted {
            throw ValidationError.duplicateName
        }
        guard record.isSynced, isRename else {
            var renamed = record
            renamed.name = validName
            renamed.kind = storedKind
            renamed.updatedAt = now
            try DestinationFieldCipher.reseal(from: record, to: &renamed, keys: keys)
            try store.updateItem(renamed, in: tx)
            try touch(destination)
            return id
        }
        // A pushed item: the old name is deleted remotely and the new one added.
        guard let value = try DestinationFieldCipher.openValue(of: record, keys: keys) else {
            throw ConfigRepositoryError.valueMissing
        }
        defer { value.wipe() }
        var tombstone = record
        tombstone.isDeleted = true
        tombstone.linkID = nil
        tombstone.updatedAt = now
        try store.updateItem(tombstone, in: tx)
        return try add(destinationID: record.destinationID, kind: storedKind, name: validName, value: value, linkID: record.linkID)
    }

    /// Deletes an item: a never-pushed row goes away, a pushed one becomes a tombstone.
    func delete(_ id: ConfigItemID) throws {
        var record = try existing(id)
        let destination = try requireDestination(record.destinationID)
        if record.isSynced {
            guard !record.isDeleted else { return }
            record.isDeleted = true
            record.forcePush = false
            record.updatedAt = now
            try store.updateItem(record, in: tx)
        } else {
            try store.deleteItem(id: id, in: tx)
        }
        try touch(destination)
    }

    /// Undoes a pending deletion or a pending add. Other changes have no stored previous value
    /// (Refresh and "Use Remote" bring the remote's value back).
    func revert(_ id: ConfigItemID) throws {
        var record = try existing(id)
        let destination = try requireDestination(record.destinationID)
        if record.isDeleted {
            record.isDeleted = false
            record.updatedAt = now
            try store.updateItem(record, in: tx)
        } else if !record.isSynced {
            try store.deleteItem(id: id, in: tx)
        } else {
            record.forcePush = false
            if record.syncedKind.map({ $0 != record.kind }) == true, let syncedKind = record.syncedKind {
                let old = record
                record.kind = syncedKind
                try DestinationFieldCipher.reseal(from: old, to: &record, keys: keys)
            }
            record.updatedAt = now
            try store.updateItem(record, in: tx)
        }
        try touch(destination)
    }

    /// Push on Next Sync.
    func requestPush(_ id: ConfigItemID) throws {
        var record = try existing(id)
        guard record.isSynced, !record.isDeleted, record.valueCiphertext != nil else { return }
        record.forcePush = true
        record.updatedAt = now
        try store.updateItem(record, in: tx)
    }

    /// "Mark as Public" (R10): the value is meant to be public, so a credential-looking value
    /// under a public prefix no longer blocks the Sync.
    func setPublicAllowed(_ id: ConfigItemID, _ allowed: Bool) throws {
        var record = try existing(id)
        guard record.isPublicAllowed != allowed else { return }
        record.isPublicAllowed = allowed
        record.updatedAt = now
        try store.updateItem(record, in: tx)
    }

    private func requireSize(_ value: SecretBytes, provider: DestinationProvider) throws {
        let limit = DestinationRules.maxValueBytes(for: provider)
        guard value.count <= limit else { throw ValidationError.valueTooLarge(limit: limit) }
    }

    /// The destination's `updated_at` follows its items.
    private func touch(_ destination: DestinationRecord) throws {
        var destination = destination
        destination.updatedAt = now
        try store.updateDestination(destination, in: tx)
    }
}
