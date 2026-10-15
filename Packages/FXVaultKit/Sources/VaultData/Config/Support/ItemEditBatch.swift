import Foundation
import SyncEngine
import VaultCore
import VaultCrypto
import VaultStore

/// Item edits of one repository inside one `VaultSession.write` transaction (§7.1).
///
/// Each edit asks `ConfigItemEditPlanner` for the row mutations, writes them through
/// ``ItemMutationWriter`` and continues from the planner's result, so several edits (a `.env`
/// import, Discard all) compose in one transaction. Capability, scope and capacity checks happen
/// here; the planner owns coalescing, tombstone revival and name uniqueness.
///
/// Values passed in must already be normalized (D32); the batch never keeps them.
struct ItemEditBatch {
    let repository: RepoModel
    private(set) var environments: [EnvironmentModel]
    private(set) var planner: ConfigItemEditPlanner
    private let keys: UnlockedKeys
    private let tx: StoreTransaction
    private let writer: ItemMutationWriter
    private let writePolicy: WriteCollaboratorPolicy
    /// The transaction's time: when a push requested in it was requested.
    private let now: Date

    init(
        repositoryID: RepoID,
        keys: borrowing UnlockedKeys,
        tx: StoreTransaction,
        store: ConfigStore,
        now: Date,
        writePolicy: WriteCollaboratorPolicy
    ) throws {
        guard let inputs = try store.fetchPendingInputs(repositoryID: repositoryID, in: tx) else {
            throw ConfigRepositoryError.repositoryNotFound
        }
        repository = inputs.repository
        environments = inputs.environments
        planner = ConfigItemEditPlanner(items: inputs.items.map(RepoSnapshotMapper.item))
        self.keys = copy keys
        self.tx = tx
        writer = ItemMutationWriter(store: store, repositoryID: repositoryID, now: now)
        self.writePolicy = writePolicy
        self.now = now
    }

    /// The current row of `id`, or nil.
    func row(_ id: ConfigItemID) -> ConfigItemSnapshotModel? {
        planner.items.first { $0.id == id }
    }

    /// The live (not tombstoned) row of `scope` and `kind` whose name folds like `name`.
    func liveRow(scope: ConfigScope, kind: ConfigKind, name: String) -> ConfigItemSnapshotModel? {
        let key = GitHubNameValidator.foldKey(name)
        return planner.items.first { !$0.isDeleted && $0.scope == scope && $0.kind == kind && $0.nameKey == key }
    }

    // MARK: - Edits

    /// Adds an item, or revives a tombstone of the same name. Returns the row holding it.
    @discardableResult
    mutating func add(scope: ConfigScope, kind: ConfigKind, name: String, value: SecretBytes) throws -> ConfigItemID {
        try requireEditable(scope)
        try requireCapacity(adding: kind, to: scope)
        let keys = keys
        let outcome = try planner.add(scope: scope, kind: kind, name: name) { keys.fingerprint(value, rowID: $0) }
        try commit(outcome, value: value)
        return try holder(scope: scope, kind: kind, name: name, in: outcome)
    }

    /// Replaces the local value.
    mutating func editValue(_ id: ConfigItemID, value: SecretBytes) throws {
        let current = try existing(id)
        try requireEditable(current.scope)
        let keys = keys
        try commit(try planner.editValue(id) { keys.fingerprint(value, rowID: $0) }, value: value)
    }

    /// Renames an item. Returns the row now holding the name (a revived tombstone, §7.1).
    @discardableResult
    mutating func rename(_ id: ConfigItemID, to name: String) throws -> ConfigItemID {
        let current = try existing(id)
        try requireEditable(current.scope)
        let value = try storedValue(of: id)
        defer { value?.wipe() }
        let keys = keys
        let outcome = try planner.rename(id, to: name) { target in value.map { keys.fingerprint($0, rowID: target) } }
        try commit(outcome, value: nil)
        return try holder(scope: current.scope, kind: current.kind, name: name, in: outcome)
    }

    /// Deletes an item: an unsynced row is removed, a synced one becomes a tombstone.
    mutating func delete(_ id: ConfigItemID) throws {
        let current = try existing(id)
        try requireEditable(current.scope)
        try commit(try planner.delete(id), value: nil)
    }

    /// Restores the synced name and value (§7.1 Revert). Always allowed: it only removes local
    /// changes.
    mutating func revert(_ id: ConfigItemID) throws {
        _ = try existing(id)
        try commit(try planner.revert(id), value: nil)
    }

    /// Fills a value-missing secret (§7.1, §7.8). `isUserRequest` records the push as the
    /// user's explicit choice (`force_push_requested_at := now`, D27); a share import passes
    /// false.
    mutating func fill(_ id: ConfigItemID, value: SecretBytes, pushOnNextSync: Bool, isUserRequest: Bool) throws {
        let current = try existing(id)
        try requireEditable(current.scope)
        let keys = keys
        let outcome = try planner.fill(
            id,
            pushOnNextSync: pushOnNextSync,
            requestedAt: isUserRequest ? now : nil
        ) { keys.fingerprint(value, rowID: $0) }
        try commit(outcome, value: value)
    }

    /// Push on Next Sync: the next Sync re-sends the secret's local value even if unchanged.
    mutating func requestPush(_ id: ConfigItemID) throws {
        let current = try existing(id)
        try requireEditable(current.scope)
        try commit(try planner.requestPush(id, requestedAt: now), value: nil)
    }

    /// Convert / Move (D11): a new row in `kind` and `scope` plus a tombstone (or removal) of the
    /// source. Returns the row now holding the item.
    @discardableResult
    mutating func move(_ id: ConfigItemID, kind: ConfigKind, scope: ConfigScope) throws -> ConfigItemID {
        let current = try existing(id)
        try requireEditable(current.scope)
        guard current.kind != kind || current.scope != scope else { return id }
        try requireEditable(scope)
        if kind == .variable, !current.hasValue {
            throw ConfigRepositoryError.valueMissing
        }
        try requireCapacity(adding: kind, to: scope)
        let value = try storedValue(of: id)
        defer { value?.wipe() }
        let keys = keys
        let outcome = try planner.move(id, kind: kind, scope: scope) { target in
            value.map { keys.fingerprint($0, rowID: target) }
        }
        try commit(outcome, value: nil)
        return try holder(scope: scope, kind: kind, name: current.name, in: outcome)
    }

    /// Discard all (§7.1): reverts every item with a pending change.
    mutating func discardAll() throws {
        try commit(try planner.discardAll(), value: nil)
    }

    // MARK: - Checks

    /// Throws unless items at `scope` can be changed: capability, and an existing environment
    /// that is not a tombstone.
    func requireEditable(_ scope: ConfigScope) throws {
        let capability = repository.capability(writePolicy: writePolicy)
        if let reason = capability.readOnlyReason(for: scope.level) {
            throw ConfigRepositoryError.readOnly(reason)
        }
        guard let environmentID = scope.environmentID else { return }
        guard let environment = environments.first(where: { $0.id == environmentID }) else {
            throw ConfigRepositoryError.environmentNotFound
        }
        if environment.isDeleted {
            throw ConfigRepositoryError.environmentDeleted
        }
    }

    /// Throws `scopeFull` when one more live item of `kind` does not fit in `scope`.
    private func requireCapacity(adding kind: ConfigKind, to scope: ConfigScope) throws {
        let count = planner.items.filter { $0.scope == scope && $0.kind == kind && !$0.isDeleted }.count
        try ScopeCapacityValidator.validate(currentCount: count, kind: kind, level: scope.level)
    }

    private func existing(_ id: ConfigItemID) throws -> ConfigItemSnapshotModel {
        guard let row = row(id) else { throw ConfigRepositoryError.itemNotFound }
        return row
    }

    // MARK: - Private

    private mutating func commit(_ outcome: ItemEditOutcomeModel, value: SecretBytes?) throws {
        try writer.apply(outcome.mutations, newValue: value, keys: keys, in: tx)
        planner = outcome.planner
    }

    /// The stored local value of `id` (nil when missing). The caller wipes it.
    private func storedValue(of id: ConfigItemID) throws -> SecretBytes? {
        guard let record = try writer.store.fetchItemRecord(id: id, in: tx) else {
            throw ConfigRepositoryError.itemNotFound
        }
        return try ConfigFieldCipher.openValue(of: record, keys: keys)
    }

    private func holder(
        scope: ConfigScope,
        kind: ConfigKind,
        name: String,
        in outcome: ItemEditOutcomeModel
    ) throws -> ConfigItemID {
        let key = GitHubNameValidator.foldKey(name)
        guard let row = outcome.items.first(where: {
            !$0.isDeleted && $0.scope == scope && $0.kind == kind && $0.nameKey == key
        }) else { throw ConfigRepositoryError.itemNotFound }
        return row.id
    }
}
