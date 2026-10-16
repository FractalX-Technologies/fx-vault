import Foundation
import os
import VaultCore
import VaultCrypto
import VaultStore

/// Linked copies (v0.4.1, tasks/todo.md L1–L5).
///
/// ``copyItems(_:to:repositoryID:conflicts:)`` links every copy to its source (`link_id`). The
/// link is local metadata only: it never travels in shares, chat or `.env` files, and it does
/// not change how a row syncs. Whether two copies hold the same value is never stored: it is
/// computed here when it is asked for (decrypted in memory, compared in constant time, wiped).
extension ConfigRepository {
    /// The other live places of `id`'s link group, each compared with `id`'s value, ordered by
    /// account, repository, scope (repository level first) and name. Empty when `id` is not
    /// linked or is the group's only live item.
    ///
    /// - Throws: `.itemNotFound`, `.vault` (locked).
    public func linkedCopies(of id: ConfigItemID) throws(ConfigRepositoryError) -> [LinkedCopyModel] {
        try performConfig {
            try session.read { keys, tx in
                guard let item = try store.fetchItemRecord(id: id, in: tx) else {
                    throw ConfigRepositoryError.itemNotFound
                }
                guard let linkID = item.linkID else { return [] }
                let others = try store.fetchLinkedItemRecords(linkID: linkID, in: tx).filter { $0.id != id }
                guard !others.isEmpty else { return [] }
                let value = try ConfigFieldCipher.openValue(of: item, keys: keys)
                defer { value?.wipe() }
                let repositories = RepoStore(database: session.database)
                var copies: [LinkedCopyModel] = []
                for other in others {
                    guard let repository = try repositories.fetch(id: other.repositoryID, in: tx) else { continue }
                    let environment = try other.environmentID.flatMap { try store.fetchEnvironment(id: $0, in: tx) }
                    copies.append(LinkedCopyModel(
                        itemID: other.id,
                        repositoryID: other.repositoryID,
                        accountLogin: repository.accountLogin,
                        repositoryFullName: repository.fullName,
                        scope: other.scope,
                        environmentName: environment?.name,
                        kind: other.kind,
                        name: other.name,
                        comparison: try Self.compare(value, with: other, keys: keys),
                        syncStatus: other.model.syncStatus,
                        editBlock: editBlock(for: other, repository: repository, environment: environment)
                    ))
                }
                return copies.sorted(by: Self.placeOrder)
            }
        }
    }

    /// Takes `id` out of its link group. When only one live item of the group is left, that
    /// item is unlinked too. Link metadata only: always allowed, nothing becomes pending.
    public func unlink(_ id: ConfigItemID) throws(ConfigRepositoryError) {
        try write { _, tx, _ in
            guard let item = try store.fetchItemRecord(id: id, in: tx) else {
                throw ConfigRepositoryError.itemNotFound
            }
            guard let linkID = item.linkID else { return }
            try store.setLinkID(nil, itemIDs: [id], in: tx)
            let rest = try store.fetchLinkedItemRecords(linkID: linkID, in: tx)
            if rest.count == 1 {
                try store.setLinkID(nil, itemIDs: rest.map(\.id), in: tx)
            }
        }
        Self.linkLog.info("Unlinked one item")
    }

    /// "Also update linked copies" (L4): gives each of `targetIDs` the local value of `id`, in
    /// one transaction across their repositories. Each target becomes an ordinary pending change
    /// (a value-missing secret is filled with a push requested now, D27), so the next Sync pushes
    /// them through the usual review. Nothing is written when one of them fails.
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
            guard let source = try store.fetchItemRecord(id: id, in: tx), let linkID = source.linkID else {
                throw ConfigRepositoryError.itemNotFound
            }
            guard let value = try ConfigFieldCipher.openValue(of: source, keys: keys) else {
                throw ConfigRepositoryError.valueMissing
            }
            defer { value.wipe() }
            var targets: [ConfigItemRecord] = []
            for targetID in Set(targetIDs) where targetID != id {
                guard let target = try store.fetchItemRecord(id: targetID, in: tx),
                      !target.isDeleted,
                      target.linkID == linkID
                else { throw ConfigRepositoryError.itemNotFound }
                targets.append(target)
            }
            for (repositoryID, records) in Dictionary(grouping: targets, by: \.repositoryID) {
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
            return targets.count
        }
        Self.linkLog.info("Updated \(count, privacy: .public) linked copies")
        return count
    }

    // MARK: - Private

    private static let linkLog = Logger(subsystem: ConfigConstants.logSubsystem, category: ConfigConstants.logCategory)

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
        with record: ConfigItemRecord,
        keys: borrowing UnlockedKeys
    ) throws -> LinkedValueComparison {
        guard let other = try ConfigFieldCipher.openValue(of: record, keys: keys) else { return .valueMissing }
        defer { other.wipe() }
        guard let value else { return .unknown }
        return value == other ? .same : .differs
    }

    private static func placeOrder(_ lhs: LinkedCopyModel, _ rhs: LinkedCopyModel) -> Bool {
        let left = (lhs.accountLogin.lowercased(), lhs.repositoryFullName.lowercased(), lhs.environmentName ?? "", lhs.name)
        let right = (rhs.accountLogin.lowercased(), rhs.repositoryFullName.lowercased(), rhs.environmentName ?? "", rhs.name)
        return left < right
    }
}
