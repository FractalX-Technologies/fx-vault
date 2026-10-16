import Foundation
import VaultCore
import VaultCrypto
import VaultStore

/// Item writes of folders inside one `VaultSession.write` transaction (v0.7.0), shared by
/// ``FolderRepository``, copy and paste, linked copies and `.env` import.
///
/// A folder has no GitHub side, so a write is final: no tombstones, no pending state. Names follow
/// ``GitHubNameValidator`` (so a folder item can be pasted into any repository) and are unique per
/// folder and kind; a folder holds at most ``Limits/maxFolderItems`` items. Values passed in must
/// already be normalized (D32).
struct FolderItemWriter {
    private let store: FolderStore
    private let keys: UnlockedKeys
    private let tx: StoreTransaction
    private let now: Date

    init(store: FolderStore, keys: borrowing UnlockedKeys, tx: StoreTransaction, now: Date) {
        self.store = store
        self.keys = copy keys
        self.tx = tx
        self.now = now
    }

    /// The folder, or `.folderNotFound`.
    func requireFolder(_ id: FolderID) throws -> FolderRecord {
        guard let folder = try store.fetchFolder(id: id, in: tx) else {
            throw ConfigRepositoryError.folderNotFound
        }
        return folder
    }

    /// The item, or `.itemNotFound`.
    func existing(_ id: ConfigItemID) throws -> FolderItemRecord {
        guard let record = try store.fetchItemRecord(id: id, in: tx) else {
            throw ConfigRepositoryError.itemNotFound
        }
        return record
    }

    /// The item of `folderID` and `kind` whose name folds like `name`, or nil.
    func row(folderID: FolderID, kind: ConfigKind, name: String) throws -> FolderItemRecord? {
        let key = GitHubNameValidator.foldKey(name)
        return try store.fetchItemRecords(folderID: folderID, in: tx).first {
            $0.kind == kind && GitHubNameValidator.foldKey($0.name) == key
        }
    }

    /// Adds an item. Returns its id.
    ///
    /// - Throws: `.validation` for an invalid name or one the folder already has for `kind`
    ///   (`.duplicateName`), `.folderFull`, `.folderNotFound`.
    @discardableResult
    func add(folderID: FolderID, kind: ConfigKind, name: String, value: SecretBytes, linkID: ItemLinkID? = nil) throws -> ConfigItemID {
        try touch(try requireFolder(folderID))
        let validName = try GitHubNameValidator.validate(name)
        let items = try store.fetchItemRecords(folderID: folderID, in: tx)
        guard items.count < Limits.maxFolderItems else {
            throw ConfigRepositoryError.folderFull(limit: Limits.maxFolderItems)
        }
        let key = GitHubNameValidator.foldKey(validName)
        guard !items.contains(where: { $0.kind == kind && GitHubNameValidator.foldKey($0.name) == key }) else {
            throw ValidationError.duplicateName
        }
        var record = FolderItemRecord(
            folderID: folderID,
            kind: kind,
            name: validName,
            valueCiphertext: Data(),
            valueFingerprint: Data(),
            linkID: linkID,
            createdAt: now,
            updatedAt: now
        )
        try FolderFieldCipher.setValue(value, on: &record, keys: keys)
        try store.insertItem(record, in: tx)
        return record.id
    }

    /// Replaces an item's value.
    func editValue(_ id: ConfigItemID, value: SecretBytes) throws {
        var record = try existing(id)
        try FolderFieldCipher.setValue(value, on: &record, keys: keys)
        record.updatedAt = now
        try store.updateItem(record, in: tx)
        try touch(try requireFolder(record.folderID))
    }

    /// Renames an item and, when `kind` differs, makes it the other kind; the value is re-sealed
    /// under the new identity. A name or kind the folder already has is refused.
    func update(_ id: ConfigItemID, name: String, kind: ConfigKind) throws {
        var record = try existing(id)
        let validName = try GitHubNameValidator.validate(name)
        guard validName != record.name || kind != record.kind else { return }
        if let other = try row(folderID: record.folderID, kind: kind, name: validName), other.id != id {
            throw ValidationError.duplicateName
        }
        let value = try FolderFieldCipher.openValue(of: record, keys: keys)
        defer { value.wipe() }
        record.name = validName
        record.kind = kind
        try FolderFieldCipher.setValue(value, on: &record, keys: keys)
        record.updatedAt = now
        try store.updateItem(record, in: tx)
        try touch(try requireFolder(record.folderID))
    }

    /// Removes an item (a folder has no GitHub side, so nothing stays behind).
    func delete(_ id: ConfigItemID) throws {
        let record = try existing(id)
        try store.deleteItem(id: id, in: tx)
        try touch(try requireFolder(record.folderID))
    }

    /// The folder's `updated_at` follows its items.
    private func touch(_ folder: FolderRecord) throws {
        var folder = folder
        folder.updatedAt = now
        try store.updateFolder(folder, in: tx)
    }
}
