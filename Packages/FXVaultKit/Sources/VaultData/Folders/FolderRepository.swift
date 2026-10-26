import Foundation
import os
import SharingKit
import VaultCore
import VaultCrypto
import VaultStore

/// Folders of secrets and variables (v0.7.0, tasks/todo.md F1–F6): named collections that belong
/// to no repository or account and are never pushed by themselves.
///
/// - Every mutation is one `VaultSession.write` transaction (an unlocked vault, serialized with
///   DEK rotation) and is final: a folder has no GitHub side, so nothing becomes pending.
/// - Values are normalized on entry (D32) and stored only as ciphertext bound to row, folder,
///   kind and name (`FolderFieldAAD`) plus a row-bound fingerprint.
/// - Copies into a folder come from any repository scope or folder and are linked to their
///   source, as copies between repositories are (``ConfigRepository/copyItems(_:to:repositoryID:conflicts:)``
///   takes folder items as sources).
/// - Observation streams need no keys and work while locked.
public struct FolderRepository: Sendable {
    public let session: VaultSession
    private let clock: any VaultClock

    public init(session: VaultSession, clock: any VaultClock = SystemClock()) {
        self.session = session
        self.clock = clock
    }

    var store: FolderStore {
        FolderStore(database: session.database)
    }

    // MARK: - Folders

    /// Creates a folder at the end of the sidebar order.
    ///
    /// - Throws: `.validation` for an invalid name or one another folder has
    ///   (`.duplicateName`, case-insensitive).
    @discardableResult
    public func createFolder(named name: String) throws(ConfigRepositoryError) -> FolderID {
        let id = try write { _, tx, now in
            let validName = try FolderNameValidator.validate(name)
            try requireAvailable(validName, except: nil, in: tx)
            let record = FolderRecord(name: validName, sortOrder: try store.nextSortOrder(in: tx), createdAt: now, updatedAt: now)
            try store.insertFolder(record, in: tx)
            return record.id
        }
        Self.log.info("Created a folder")
        return id
    }

    /// Renames a folder. A case-only change is allowed.
    public func renameFolder(_ id: FolderID, to name: String) throws(ConfigRepositoryError) {
        try write { _, tx, now in
            guard var folder = try store.fetchFolder(id: id, in: tx) else { throw ConfigRepositoryError.folderNotFound }
            let validName = try FolderNameValidator.validate(name)
            guard validName != folder.name else { return }
            try requireAvailable(validName, except: id, in: tx)
            folder.name = validName
            folder.nameKey = FolderNameValidator.foldKey(validName)
            folder.updatedAt = now
            try store.updateFolder(folder, in: tx)
        }
    }

    /// Deletes a folder and its items. Their copies in repositories stay where they are; a copy
    /// left alone in its link group is no longer shown as linked.
    public func deleteFolder(_ id: FolderID) throws(ConfigRepositoryError) {
        try write { _, tx, _ in
            guard try store.deleteFolder(id: id, in: tx) else { throw ConfigRepositoryError.folderNotFound }
        }
        Self.log.info("Deleted a folder")
    }

    /// Puts the folders in the order of `ids` (the sidebar after a drag), which must list every
    /// folder once.
    public func reorderFolders(_ ids: [FolderID]) throws(ConfigRepositoryError) {
        try write { _, tx, now in
            let folders = try store.fetchFolderRecords(in: tx)
            guard Set(ids) == Set(folders.map(\.id)), ids.count == folders.count else {
                throw ConfigRepositoryError.folderNotFound
            }
            let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
            for (order, id) in ids.enumerated() {
                guard var folder = byID[id], folder.sortOrder != order else { continue }
                folder.sortOrder = order
                folder.updatedAt = now
                try store.updateFolder(folder, in: tx)
            }
        }
    }

    /// Every folder in the sidebar order, with its counts.
    public func folders() throws(ConfigRepositoryError) -> [FolderModel] {
        try performConfig { try store.fetchFolders() }
    }

    /// Every folder with its counts, now and after each change (the sidebar).
    public func observeFolders() -> AsyncThrowingStream<[FolderModel], any Error> {
        store.observeFolders()
    }

    // MARK: - Items

    /// The items of one folder, with their link counts.
    public func items(folderID: FolderID) throws(ConfigRepositoryError) -> [FolderItemModel] {
        try performConfig { try store.fetchItems(folderID: folderID) }
    }

    /// The items of one folder, now and after each change.
    public func observeItems(folderID: FolderID) -> AsyncThrowingStream<[FolderItemModel], any Error> {
        store.observeItems(folderID: folderID)
    }

    /// Adds a secret or variable. The value is normalized first (D32).
    ///
    /// - Throws: `.validation` (invalid name, a name the folder already has for `kind`, an empty
    ///   or oversized value), `.folderFull`, `.folderNotFound`, `.vault(.locked)`.
    @discardableResult
    public func addItem(
        folderID: FolderID,
        kind: ConfigKind,
        name: String,
        value: SecretBytes,
        file: FileSecretModel? = nil
    ) throws(ConfigRepositoryError) -> ItemWriteResultModel {
        let normalized = try Self.normalize(value)
        defer { normalized.value.wipe() }
        let id = try write { keys, tx, now in
            try writer(keys, tx, now).add(folderID: folderID, kind: kind, name: name, value: normalized.value, file: file)
        }
        return ItemWriteResultModel(itemID: id, didStripTrailingNewlines: normalized.didStripTrailingNewlines)
    }

    /// Saves an edit in one transaction: the name and kind (the value is re-sealed for them) and,
    /// when `value` is given, a new value.
    @discardableResult
    public func editItem(
        _ id: ConfigItemID,
        name: String,
        kind: ConfigKind,
        value: SecretBytes?
    ) throws(ConfigRepositoryError) -> ItemWriteResultModel {
        let normalized = try value.map { value throws(ConfigRepositoryError) in try Self.normalize(value) }
        defer { normalized?.value.wipe() }
        try write { keys, tx, now in
            let writer = writer(keys, tx, now)
            try writer.update(id, name: name, kind: kind)
            if let normalized {
                try writer.editValue(id, value: normalized.value)
            }
        }
        return ItemWriteResultModel(itemID: id, didStripTrailingNewlines: normalized?.didStripTrailingNewlines ?? false)
    }

    /// Deletes items of folders in one transaction. Their linked copies stay where they are.
    public func deleteItems(_ ids: [ConfigItemID]) throws(ConfigRepositoryError) {
        try write { keys, tx, now in
            let writer = writer(keys, tx, now)
            for id in ids {
                try writer.delete(id)
            }
        }
        Self.log.info("Deleted \(ids.count, privacy: .public) folder items")
    }

    /// Saves the notes' edits of a folder (1.0 N2) in one transaction; nothing is written when
    /// one fails.
    public func applyEdits(_ edits: PlaceItemEditsModel, folderID: FolderID) throws(ConfigRepositoryError) {
        let normalized = try edits.normalized()
        defer { normalized.wipe() }
        try write { keys, tx, now in
            let writer = writer(keys, tx, now)
            _ = try writer.requireFolder(folderID)
            func requireInFolder(_ id: ConfigItemID) throws -> FolderItemRecord {
                let record = try writer.existing(id)
                guard record.folderID == folderID else { throw ConfigRepositoryError.itemNotFound }
                return record
            }
            for id in normalized.deletions {
                _ = try requireInFolder(id)
                try writer.delete(id)
            }
            for change in normalized.changes {
                let current = try requireInFolder(change.id)
                if let name = change.name {
                    try writer.update(change.id, name: name, kind: current.kind)
                }
                if let value = change.value {
                    try writer.editValue(change.id, value: value)
                }
            }
            for addition in normalized.additions {
                try writer.add(folderID: folderID, kind: addition.kind, name: addition.name, value: addition.value)
            }
        }
        Self.log.info("Saved \(edits.count, privacy: .public) folder edits from the notes")
    }

    /// The decrypted value of a folder item, for Reveal, Copy and Edit. The caller wipes it.
    public func reveal(_ id: ConfigItemID) throws(ConfigRepositoryError) -> SecretBytes {
        try performConfig {
            try session.read { keys, tx in
                guard let record = try store.fetchItemRecord(id: id, in: tx) else {
                    throw ConfigRepositoryError.itemNotFound
                }
                return try FolderFieldCipher.openValue(of: record, keys: keys)
            }
        }
    }

    // MARK: - Copy and paste

    /// The names among `ids` that the folder already holds (same kind): the copy asks whether to
    /// replace or keep those items. Sources may be repository or folder items; deleted and missing
    /// ids, and items already in this folder, are ignored here.
    public func copyConflicts(_ ids: [ConfigItemID], to folderID: FolderID) throws(ConfigRepositoryError) -> [String] {
        try performConfig {
            try session.database.read { tx in
                let taken = Set(try store.fetchItemRecords(folderID: folderID, in: tx).map {
                    ConfigRepository.TargetKey(kind: $0.kind, name: GitHubNameValidator.foldKey($0.name))
                })
                return try ids.compactMap { id in
                    guard let source = try ItemCopySource.load(id, database: session.database, in: tx),
                          !source.isDeleted,
                          !source.isIn(.folder(folderID)),
                          taken.contains(ConfigRepository.TargetKey(kind: source.kind, name: GitHubNameValidator.foldKey(source.name)))
                    else { return nil }
                    return source.name
                }
            }
        }
    }

    /// Copies items into a folder in one transaction, each linked to its source. A name the folder
    /// already has for that kind is replaced or kept (`conflicts`); value-missing repository
    /// secrets are not copied (listed in the result). Nothing is written when one of them fails.
    @discardableResult
    public func copyItems(
        _ ids: [ConfigItemID],
        to folderID: FolderID,
        conflicts: ItemCopyConflictPolicy
    ) throws(ConfigRepositoryError) -> ItemCopyResultModel {
        let result = try write { keys, tx, now in
            let writer = writer(keys, tx, now)
            _ = try writer.requireFolder(folderID)
            var result = ItemCopyResultModel()
            for id in ids {
                guard let source = try ItemCopySource.load(id, database: session.database, in: tx), !source.isDeleted else {
                    throw ConfigRepositoryError.itemNotFound
                }
                guard !source.isIn(.folder(folderID)) else { continue }
                guard let value = try source.openValue(keys: keys) else {
                    result.withoutValue.append(source.name)
                    continue
                }
                defer { value.wipe() }
                let copyID: ConfigItemID
                if let existing = try writer.row(folderID: folderID, kind: source.kind, name: source.name) {
                    switch conflicts {
                    case .keep:
                        result.kept += 1
                        continue
                    case .replace:
                        try writer.editValue(existing.id, value: value, file: source.file)
                        copyID = existing.id
                        result.replaced += 1
                    }
                } else {
                    copyID = try writer.add(folderID: folderID, kind: source.kind, name: source.name, value: value, file: source.file)
                    result.added += 1
                }
                try source.link(copy: copyID, database: session.database, in: tx)
            }
            return result
        }
        Self.log.info("Copied \(result.added + result.replaced, privacy: .public) items into a folder")
        return result
    }

    // MARK: - Received copies (F7)

    /// "Save as Folder" for a folder package opened from a `.fxvault` file: a new folder, or merged into an existing one where a name it already has for that
    /// kind is replaced or kept. Values are normalized (D32); received items are not linked to
    /// anything. The package id is recorded, as an import's is. One transaction; nothing is
    /// written when one item fails. Does not wipe `package`.
    ///
    /// - Throws: `.validation` (a name another folder has, an invalid name), `.folderNotFound`,
    ///   `.folderFull`, `.unexpected` for a package that is not a valid folder copy,
    ///   `.vault(.locked)`.
    @discardableResult
    public func save(
        _ package: SharePackageModel,
        as target: FolderSaveTargetModel,
        conflicts: ItemCopyConflictPolicy
    ) throws(ConfigRepositoryError) -> FolderSaveResultModel {
        guard package.isFolder, SharePackageValidator.violation(in: package, mode: .payload) == nil else {
            throw .unexpected
        }
        let result = try write { keys, tx, now in
            let folderID: FolderID
            switch target {
            case .newFolder(let name):
                let validName = try FolderNameValidator.validate(name)
                try requireAvailable(validName, except: nil, in: tx)
                let record = FolderRecord(name: validName, sortOrder: try store.nextSortOrder(in: tx), createdAt: now, updatedAt: now)
                try store.insertFolder(record, in: tx)
                folderID = record.id
            case .existing(let id):
                folderID = id
            }
            let writer = writer(keys, tx, now)
            _ = try writer.requireFolder(folderID)
            var items = ItemCopyResultModel()
            for located in package.flattenedItems {
                guard let received = located.item.value else { throw ConfigRepositoryError.valueMissing }
                let normalized = try Self.normalize(received)
                defer { normalized.value.wipe() }
                if let existing = try writer.row(folderID: folderID, kind: located.kind, name: located.item.name) {
                    switch conflicts {
                    case .keep:
                        items.kept += 1
                    case .replace:
                        try writer.editValue(existing.id, value: normalized.value)
                        items.replaced += 1
                    }
                } else {
                    try writer.add(folderID: folderID, kind: located.kind, name: located.item.name, value: normalized.value)
                    items.added += 1
                }
            }
            let sender = package.sender.displayName
            try SharePackageStore(database: session.database).recordImport(
                ImportedSharePackageRecord(
                    packageID: package.packageID,
                    createdAt: package.createdAt,
                    importedAt: now,
                    senderName: sender.isEmpty ? nil : sender
                ),
                in: tx
            )
            return FolderSaveResultModel(folderID: folderID, items: items)
        }
        Self.log.info("Saved a received folder: \(result.items.added, privacy: .public) added, \(result.items.replaced, privacy: .public) replaced")
        return result
    }

    /// True when a package with this id was imported or saved before (the replay note).
    public func wasImported(_ packageID: SharePackageID) throws(ConfigRepositoryError) -> Bool {
        try performConfig { try SharePackageStore(database: session.database).hasImported(packageID) }
    }

    // MARK: - Private

    private static let log = Logger(subsystem: ConfigConstants.logSubsystem, category: "folders")

    private static func normalize(_ value: SecretBytes) throws(ConfigRepositoryError) -> ValueNormalizer.NormalizedValue {
        do {
            return try ValueNormalizer.normalize(value)
        } catch {
            throw .validation(error)
        }
    }

    private func requireAvailable(_ name: String, except id: FolderID?, in tx: StoreTransaction) throws {
        let key = FolderNameValidator.foldKey(name)
        if try store.fetchFolderRecords(in: tx).contains(where: { $0.id != id && $0.nameKey == key }) {
            throw ValidationError.duplicateName
        }
    }

    private func writer(_ keys: borrowing UnlockedKeys, _ tx: StoreTransaction, _ now: Date) -> FolderItemWriter {
        FolderItemWriter(store: store, keys: keys, tx: tx, now: now)
    }

    /// One write transaction with the keys and the current time.
    func write<Result>(
        _ body: (borrowing UnlockedKeys, StoreTransaction, Date) throws -> Result
    ) throws(ConfigRepositoryError) -> Result {
        let now = clock.now
        return try performConfig {
            try session.write { keys, tx in try body(keys, tx, now) }
        }
    }
}
