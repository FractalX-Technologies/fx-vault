import Foundation
import os
import VaultCore
import VaultCrypto
import VaultStore

/// Linked copies (v0.4.1, tasks/todo.md L1–L5).
///
/// ``copyItems(_:to:repositoryID:conflicts:)`` links every copy to its source (`link_id`). The
/// link is local metadata only: it never travels in shares or `.env` files, and it does
/// not change how a row syncs. Whether two copies hold the same value is never stored: it is
/// computed here when it is asked for (decrypted in memory, compared in constant time, wiped).
extension ConfigRepository {
    /// The other live places of `id`'s link group (repository scopes and folders, v0.7.0), each
    /// compared with `id`'s value: folders first by name, then by account, repository, scope
    /// (repository level first) and name. `id` may be a repository or a folder item. Empty when
    /// `id` is not linked or is the group's only live item.
    ///
    /// - Throws: `.itemNotFound`, `.vault` (locked).
    public func linkedCopies(of id: ConfigItemID) throws(ConfigRepositoryError) -> [LinkedCopyModel] {
        try performConfig {
            try session.read { keys, tx in
                guard let item = try ItemCopySource.load(id, database: session.database, in: tx) else {
                    throw ConfigRepositoryError.itemNotFound
                }
                guard let linkID = item.linkID else { return [] }
                let others = try ItemCopySource.linkGroup(linkID, database: session.database, in: tx).filter { $0.id != id }
                guard !others.isEmpty else { return [] }
                let value = try item.openValue(keys: keys)
                defer { value?.wipe() }
                var copies: [LinkedCopyModel] = []
                for other in others {
                    guard let copy = try linkedCopy(other, comparedWith: value, keys: keys, in: tx) else { continue }
                    copies.append(copy)
                }
                return copies.sorted(by: Self.placeOrder)
            }
        }
    }

    /// Takes `id` (a repository or folder item) out of its link group. When only one live item of
    /// the group is left, that item is unlinked too. Link metadata only: always allowed, nothing
    /// becomes pending.
    public func unlink(_ id: ConfigItemID) throws(ConfigRepositoryError) {
        try write { _, tx, _ in
            let database = session.database
            guard let item = try ItemCopySource.load(id, database: database, in: tx) else {
                throw ConfigRepositoryError.itemNotFound
            }
            guard let linkID = item.linkID else { return }
            try ItemCopySource.setLinkID(nil, itemIDs: [id], database: database, in: tx)
            let rest = try ItemCopySource.linkGroup(linkID, database: database, in: tx)
            if rest.count == 1 {
                try ItemCopySource.setLinkID(nil, itemIDs: rest.map(\.id), database: database, in: tx)
            }
        }
        Self.linkLog.info("Unlinked one item")
    }

    /// "Also update linked copies" (L4): gives each of `targetIDs` the value of `id`, in one
    /// transaction across their repositories and folders (v0.7.0). A repository target becomes
    /// an ordinary pending change (a value-missing secret is filled with a push requested now,
    /// D27), so the next Sync pushes it through the usual review; a folder target changes at
    /// once. Nothing is written when one of them fails.
    ///
    /// - Returns: how many copies were updated.
    /// - Throws: `.itemNotFound` (a target is gone, deleted or no longer in `id`'s group),
    ///   `.valueMissing` (`id` has no value), `.readOnly`, `.environmentDeleted`, `.vault`.
    @discardableResult
    public func updateLinkedCopies(
        from id: ConfigItemID,
        to targetIDs: [ConfigItemID]
    ) throws(ConfigRepositoryError) -> Int {
        guard !targetIDs.isEmpty else { return 0 }
        let count = try write { keys, tx, now in
            let database = session.database
            guard let source = try ItemCopySource.load(id, database: database, in: tx), let linkID = source.linkID else {
                throw ConfigRepositoryError.itemNotFound
            }
            guard let value = try source.openValue(keys: keys) else {
                throw ConfigRepositoryError.valueMissing
            }
            defer { value.wipe() }
            var repositoryTargets: [ConfigItemRecord] = []
            var folderTargets: [FolderItemRecord] = []
            var destinationTargets: [DestinationItemRecord] = []
            for targetID in Set(targetIDs) where targetID != id {
                guard let target = try ItemCopySource.load(targetID, database: database, in: tx),
                      !target.isDeleted,
                      target.linkID == linkID
                else { throw ConfigRepositoryError.itemNotFound }
                if let record = target.configRecord {
                    repositoryTargets.append(record)
                } else if let record = target.folderRecord {
                    folderTargets.append(record)
                } else if let record = target.destinationRecord {
                    destinationTargets.append(record)
                }
            }
            for (repositoryID, records) in Dictionary(grouping: repositoryTargets, by: \.repositoryID) {
                var batch = try ItemEditBatch(
                    repositoryID: repositoryID,
                    keys: keys,
                    tx: tx,
                    store: store,
                    now: now,
                    writePolicy: writePolicy
                )
                for record in records {
                    if record.valueCiphertext == nil {
                        try batch.fill(record.id, value: value, pushOnNextSync: true, isUserRequest: true)
                    } else {
                        try batch.editValue(record.id, value: value)
                    }
                }
            }
            let folderWriter = FolderItemWriter(store: FolderStore(database: database), keys: keys, tx: tx, now: now)
            for record in folderTargets {
                try folderWriter.editValue(record.id, value: value)
            }
            let destinationWriter = DestinationItemWriter(store: DestinationStore(database: database), keys: keys, tx: tx, now: now)
            for record in destinationTargets {
                try destinationWriter.editValue(record.id, value: value)
            }
            return repositoryTargets.count + folderTargets.count + destinationTargets.count
        }
        Self.linkLog.info("Updated \(count, privacy: .public) linked copies")
        return count
    }

    // MARK: - Private

    private static let linkLog = Logger(subsystem: ConfigConstants.logSubsystem, category: ConfigConstants.logCategory)

    /// One place of a link group, or nil when its repository or folder is gone.
    private func linkedCopy(
        _ other: ItemCopySource,
        comparedWith value: SecretBytes?,
        keys: borrowing UnlockedKeys,
        in tx: StoreTransaction
    ) throws -> LinkedCopyModel? {
        let comparison = try Self.compare(value, with: other, keys: keys)
        if let record = other.configRecord {
            guard let repository = try RepoStore(database: session.database).fetch(id: record.repositoryID, in: tx) else { return nil }
            let environment = try record.environmentID.flatMap { try store.fetchEnvironment(id: $0, in: tx) }
            return LinkedCopyModel(
                itemID: record.id,
                place: .scope(
                    repositoryID: record.repositoryID,
                    accountLogin: repository.accountLogin,
                    repositoryFullName: repository.fullName,
                    scope: record.scope,
                    environmentName: environment?.name
                ),
                kind: record.kind,
                name: record.name,
                comparison: comparison,
                syncStatus: record.model.syncStatus,
                editBlock: editBlock(for: record, repository: repository, environment: environment)
            )
        }
        if let record = other.destinationRecord {
            let destinations = DestinationStore(database: session.database)
            guard let destination = try destinations.fetchDestination(id: record.destinationID, in: tx) else { return nil }
            let repository = try destination.repositoryID.map { id in try RepoStore(database: session.database).fetch(id: id, in: tx) }
            if destination.repositoryID != nil, repository == nil { return nil }
            return LinkedCopyModel(
                itemID: record.id,
                place: .destination(
                    destination.id,
                    repositoryID: repository??.id,
                    repositoryFullName: repository??.fullName,
                    provider: destination.provider,
                    displayName: try destination.target().displayName,
                    stage: destination.stage
                ),
                kind: record.kind,
                name: record.name,
                comparison: comparison,
                syncStatus: record.syncStatus,
                editBlock: nil
            )
        }
        guard let record = other.folderRecord,
              let folder = try FolderStore(database: session.database).fetchFolder(id: record.folderID, in: tx)
        else { return nil }
        return LinkedCopyModel(
            itemID: record.id,
            place: .folder(folder.id, name: folder.name),
            kind: record.kind,
            name: record.name,
            comparison: comparison,
            syncStatus: nil,
            editBlock: nil
        )
    }

    /// Why `record` cannot take a new value, or nil (the checks of `ItemEditBatch.requireEditable`).
    private func editBlock(
        for record: ConfigItemRecord,
        repository: RepoModel,
        environment: EnvironmentModel?
    ) -> ConfigRepositoryError? {
        if let reason = repository.capability(writePolicy: writePolicy).readOnlyReason(for: record.scope.level) {
            return .readOnly(reason)
        }
        if environment?.isDeleted == true {
            return .environmentDeleted
        }
        return nil
    }

    private static func compare(
        _ value: SecretBytes?,
        with other: ItemCopySource,
        keys: borrowing UnlockedKeys
    ) throws -> LinkedValueComparison {
        guard let otherValue = try other.openValue(keys: keys) else { return .valueMissing }
        defer { otherValue.wipe() }
        guard let value else { return .unknown }
        return value == otherValue ? .same : .differs
    }

    /// Folders first (by name), then repositories by account, repository, scope and name, then
    /// destinations by repository (Key Vaults of their own first), name and item name.
    private static func placeOrder(_ lhs: LinkedCopyModel, _ rhs: LinkedCopyModel) -> Bool {
        sortKey(lhs) < sortKey(rhs)
    }

    private static func sortKey(_ copy: LinkedCopyModel) -> (Int, String, String, String, String) {
        switch copy.place {
        case .folder(_, let name):
            (0, name.lowercased(), "", "", copy.name)
        case .scope(_, let account, let fullName, _, let environment):
            (1, account.lowercased(), fullName.lowercased(), environment ?? "", copy.name)
        case .destination(_, _, let fullName, _, let displayName, _):
            (2, fullName?.lowercased() ?? "", displayName.lowercased(), "", copy.name)
        }
    }
}
