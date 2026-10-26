import Foundation
import os
import VaultCore
import VaultCrypto
import VaultStore

/// Local changes to an organization's secrets and variables (1.0, tasks/todo.md B6b): add,
/// set a value, set who can use it, delete and revert. Nothing reaches GitHub until Sync.
///
/// - Values are normalized on entry (D32) and sealed with `OrgFieldAAD`; names never change (a
///   rename is a delete and an add), so a sealed value stays bound to its row.
/// - Deleting a synced item leaves a tombstone; deleting an add removes the row. Adding a name
///   whose deletion is pending revives that row.
/// - Revert undoes adds, deletions and access changes. A changed value cannot be reverted: the
///   vault keeps no copy of the synced value (as for destinations).
public struct OrganizationItemRepository: Sendable {
    public let session: VaultSession
    private let clock: any VaultClock

    private static let log = Logger(subsystem: ConfigConstants.logSubsystem, category: "organizations")

    public init(session: VaultSession, clock: any VaultClock = SystemClock()) {
        self.session = session
        self.clock = clock
    }

    private var store: OrganizationStore {
        OrganizationStore(database: session.database)
    }

    /// Adds a secret or variable with its access.
    ///
    /// - Throws: `.organizationNotFound`, `.validation` (name, value, repository list, a full
    ///   organization, `.duplicateName`).
    @discardableResult
    public func addItem(
        organizationID: OrganizationID,
        kind: ConfigKind,
        name: String,
        value: SecretBytes,
        access: OrgItemAccessModel
    ) throws(ConfigRepositoryError) -> ItemWriteResultModel {
        let validName = try performConfig { try GitHubNameValidator.validate(name) }
        let repositories = try performConfig { try access.validatedRepositories() }
        let normalized = try Self.normalize(value)
        defer { normalized.value.wipe() }
        let id = try write { keys, tx, now in
            guard try store.fetchOrganization(id: organizationID, in: tx) != nil else {
                throw ConfigRepositoryError.organizationNotFound
            }
            if var existing = try store.fetchItemRecord(organizationID: organizationID, kind: kind, name: validName, in: tx) {
                guard existing.isDeleted else { throw ValidationError.duplicateName }
                existing.isDeleted = false
                try Self.apply(access, repositories: repositories, to: &existing, store: store, tx: tx)
                try OrgFieldCipher.setValue(normalized.value, on: &existing, keys: keys)
                existing.updatedAt = now
                try store.updateItem(existing, in: tx)
                return existing.id
            }
            let limit = kind == .secret ? Limits.maxSecretsPerOrganization : Limits.maxVariablesPerOrganization
            guard try store.countItems(organizationID: organizationID, kind: kind, in: tx) < limit else {
                throw ValidationError.scopeFull(kind: kind, limit: limit)
            }
            var item = OrgItemRecord(organizationID: organizationID, kind: kind, name: validName, visibility: access.visibility, createdAt: now, updatedAt: now)
            try OrgFieldCipher.setValue(normalized.value, on: &item, keys: keys)
            try store.insertItem(item, in: tx)
            try Self.apply(access, repositories: repositories, to: &item, store: store, tx: tx)
            try store.updateItem(item, in: tx)
            return item.id
        }
        Self.log.info("Added an organization item")
        return ItemWriteResultModel(itemID: id, didStripTrailingNewlines: normalized.didStripTrailingNewlines)
    }

    /// Sets a new value. With `alreadyMatchesRemote` (a secret value filled in to match GitHub)
    /// nothing is pushed.
    @discardableResult
    public func setValue(_ id: ConfigItemID, value: SecretBytes, alreadyMatchesRemote: Bool = false) throws(ConfigRepositoryError) -> ItemWriteResultModel {
        let normalized = try Self.normalize(value)
        defer { normalized.value.wipe() }
        try update(id) { item, keys, _ in
            try OrgFieldCipher.setValue(normalized.value, on: &item, keys: keys)
            if alreadyMatchesRemote {
                item.syncedFingerprint = item.valueFingerprint
            }
        }
        return ItemWriteResultModel(itemID: id, didStripTrailingNewlines: normalized.didStripTrailingNewlines)
    }

    /// Sets who can use the item: a `selected` list replaces the whole list.
    public func setAccess(_ id: ConfigItemID, _ access: OrgItemAccessModel) throws(ConfigRepositoryError) {
        let repositories = try performConfig { try access.validatedRepositories() }
        try update(id) { item, _, tx in
            try Self.apply(access, repositories: repositories, to: &item, store: store, tx: tx)
        }
    }

    /// The item's repository list: the edited one the next Sync sends, else GitHub's as Import,
    /// Refresh or Sync last read it; empty when unknown.
    public func repositories(of id: ConfigItemID) throws(ConfigRepositoryError) -> [String] {
        try performConfig { try session.database.read { tx in try store.fetchRepositories(itemID: id, in: tx) } }
    }

    /// Deletes items: adds disappear, synced items wait for Sync as deletions.
    public func deleteItems(_ ids: [ConfigItemID]) throws(ConfigRepositoryError) {
        try write { _, tx, now in
            for id in ids {
                guard var item = try store.fetchItemRecord(id: id, in: tx) else { throw ConfigRepositoryError.itemNotFound }
                if item.syncedVisibility == nil {
                    try store.deleteItem(id: id, in: tx)
                } else {
                    item.isDeleted = true
                    item.updatedAt = now
                    try store.updateItem(item, in: tx)
                }
            }
        }
    }

    /// Undoes adds, deletions and access changes (not a changed value).
    public func revertItems(_ ids: [ConfigItemID]) throws(ConfigRepositoryError) {
        try write { _, tx, now in
            for id in ids {
                guard var item = try store.fetchItemRecord(id: id, in: tx) else { throw ConfigRepositoryError.itemNotFound }
                guard let synced = item.syncedVisibility else {
                    try store.deleteItem(id: id, in: tx)
                    continue
                }
                if item.repositoriesEdited || item.visibility != synced {
                    // GitHub's count and list are unknown once the access was edited; Refresh reads them.
                    // Otherwise the stored list is GitHub's and stays.
                    item.selectedCount = nil
                    try store.replaceRepositories(itemID: id, names: [], in: tx)
                }
                item.isDeleted = false
                item.visibility = synced
                item.repositoriesEdited = false
                item.updatedAt = now
                try store.updateItem(item, in: tx)
            }
        }
    }

    /// The decrypted value. The caller wipes it.
    ///
    /// - Throws: `.valueMissing` for a secret GitHub never returned, `.itemNotFound`.
    public func reveal(_ id: ConfigItemID) throws(ConfigRepositoryError) -> SecretBytes {
        try performConfig {
            try session.read { keys, tx in
                guard let item = try store.fetchItemRecord(id: id, in: tx) else { throw ConfigRepositoryError.itemNotFound }
                guard let value = try OrgFieldCipher.openValue(of: item, keys: keys) else { throw ConfigRepositoryError.valueMissing }
                return value
            }
        }
    }

    /// Pending item changes per organization (added to the Sync badge).
    public func observePendingCounts() -> AsyncThrowingStream<[OrganizationID: Int], any Error> {
        store.observePendingCounts()
    }

    public func pendingCounts() throws(ConfigRepositoryError) -> [OrganizationID: Int] {
        try performConfig { try store.fetchPendingCounts() }
    }

    // MARK: - Support

    private static func apply(
        _ access: OrgItemAccessModel,
        repositories: [String],
        to item: inout OrgItemRecord,
        store: OrganizationStore,
        tx: StoreTransaction
    ) throws {
        item.visibility = access.visibility
        item.repositoriesEdited = !repositories.isEmpty
        item.selectedCount = repositories.isEmpty ? nil : repositories.count
        try store.replaceRepositories(itemID: item.id, names: repositories, in: tx)
    }

    private func update(
        _ id: ConfigItemID,
        _ body: (inout OrgItemRecord, borrowing UnlockedKeys, StoreTransaction) throws -> Void
    ) throws(ConfigRepositoryError) {
        try write { keys, tx, now in
            guard var item = try store.fetchItemRecord(id: id, in: tx) else { throw ConfigRepositoryError.itemNotFound }
            guard !item.isDeleted else { throw ConfigRepositoryError.itemNotFound }
            try body(&item, keys, tx)
            item.updatedAt = now
            try store.updateItem(item, in: tx)
        }
    }

    private static func normalize(_ value: SecretBytes) throws(ConfigRepositoryError) -> ValueNormalizer.NormalizedValue {
        do {
            return try ValueNormalizer.normalize(value)
        } catch {
            throw .validation(error)
        }
    }

    private func write<Result>(
        _ body: (borrowing UnlockedKeys, StoreTransaction, Date) throws -> Result
    ) throws(ConfigRepositoryError) -> Result {
        let now = clock.now
        return try performConfig {
            try session.write { keys, tx in try body(keys, tx, now) }
        }
    }
}
