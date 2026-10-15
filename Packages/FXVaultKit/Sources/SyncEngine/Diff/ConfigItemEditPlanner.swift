import Foundation
import VaultCore

/// Why an item edit cannot be applied.
public enum ItemEditError: Error, Sendable, Hashable {
    /// No row with that id.
    case itemNotFound
    /// Another live row of the same scope and kind already has the name.
    case nameTaken
    /// The name fails `GitHubNameValidator`.
    case invalidName(ValidationError)
    /// Revert of a row with no synced value to restore (a variable must always have a value).
    case nothingToRevert
    /// Fill is only for a secret whose value is missing.
    case valueNotMissing
}

/// Where the new local value of a row comes from. VaultData seals it under the row's AAD
/// (§5.4: row id, scope, kind and name). A row whose `name` changed must be re-sealed even
/// when its value source is ``unchanged``.
public enum ItemValueSourceModel: Sendable, Hashable {
    /// The value stays as stored.
    case unchanged
    /// The value passed to the edit.
    case newValue
    /// The value passed to the edit, stored as both the local and the synced value
    /// (`synced_value_ct`, `synced_fp`): Fill taken as what GitHub already has (§7.1).
    case newValueAsSynced
    /// The row's own synced value (`value_ct := synced_value_ct`, Revert).
    case syncedValue
    /// The value the row with this id had before the edit (tombstone revival on rename,
    /// Convert/Move). Nil fingerprint on the result means that value was missing.
    case movedFrom(ConfigItemID)
}

/// One row operation of an edit.
public enum ItemMutationModel: Sendable, Hashable {
    case insert(ConfigItemSnapshotModel, value: ItemValueSourceModel)
    case update(ConfigItemSnapshotModel, value: ItemValueSourceModel)
    /// The row is deleted from the database (an unsynced row that is deleted or reverted).
    case remove(ConfigItemID)
}

/// The rows after an edit plus the mutations that produce them.
public struct ItemEditOutcomeModel: Sendable, Hashable {
    /// Every row of the repository after the edit.
    public var items: [ConfigItemSnapshotModel]
    /// What to write, in order.
    public var mutations: [ItemMutationModel]

    public init(items: [ConfigItemSnapshotModel], mutations: [ItemMutationModel]) {
        self.items = items
        self.mutations = mutations
    }

    /// The planner for the next edit.
    public var planner: ConfigItemEditPlanner {
        ConfigItemEditPlanner(items: items)
    }
}

/// The §7.1 editing rules, as pure decisions over one repository's item rows. VaultData's
/// `ConfigRepository` applies the mutations in one transaction.
///
/// Values never enter the planner: an edit that stores a value takes a closure returning the
/// value's row-bound fingerprint for a given row id (fingerprints are bound to the row, §5.4,
/// so a value moving to another row gets a new fingerprint).
///
/// Coalescing follows from comparing fingerprints with the synced ones:
/// - add then edit = add; add then delete = the row is removed;
/// - edit back to the synced value = no change; delete then re-add = revive;
/// - adding or renaming into a name held by a tombstone revives the tombstone: the value moves
///   onto it and the source row becomes a tombstone (or is removed when never synced);
/// - kind and scope never change on a synced row (D11): ``move(_:kind:scope:newID:fingerprint:)``
///   creates a new row plus a tombstone.
public struct ConfigItemEditPlanner: Sendable {
    public private(set) var items: [ConfigItemSnapshotModel]

    public init(items: [ConfigItemSnapshotModel]) {
        self.items = items
    }

    // MARK: - Add

    /// Adds `name` with a new value. A tombstone with that name in the same scope and kind is
    /// revived instead (delete then re-add).
    public func add(
        scope: ConfigScope,
        kind: ConfigKind,
        name: String,
        newID: ConfigItemID = ConfigItemID(),
        fingerprint: (ConfigItemID) -> Data
    ) throws(ItemEditError) -> ItemEditOutcomeModel {
        let normalized = try Self.validated(name)
        var draft = Draft(items: items)
        if let existing = draft.holder(scope: scope, kind: kind, name: normalized, excluding: nil) {
            guard existing.isDeleted else { throw .nameTaken }
            var revived = existing
            revived.isDeleted = false
            revived.valueFingerprint = fingerprint(revived.id)
            draft.update(revived, value: .newValue)
            return draft.outcome
        }
        let row = ConfigItemSnapshotModel(
            id: newID,
            scope: scope,
            kind: kind,
            name: normalized,
            valueFingerprint: fingerprint(newID)
        )
        draft.insert(row, value: .newValue)
        return draft.outcome
    }

    // MARK: - Edit value

    /// Replaces the local value. Coalesces naturally: an unsynced row stays an add, and a value
    /// equal to the synced one leaves nothing pending.
    public func editValue(_ id: ConfigItemID, fingerprint: (ConfigItemID) -> Data) throws(ItemEditError) -> ItemEditOutcomeModel {
        var draft = Draft(items: items)
        var row = try draft.existing(id)
        row.valueFingerprint = fingerprint(id)
        draft.update(row, value: .newValue)
        return draft.outcome
    }

    // MARK: - Delete

    /// An unsynced row is removed; a synced one becomes a tombstone named after its
    /// `synced_name` (kept as is when another row holds that name).
    public func delete(_ id: ConfigItemID) throws(ItemEditError) -> ItemEditOutcomeModel {
        var draft = Draft(items: items)
        let row = try draft.existing(id)
        draft.retire(row)
        return draft.outcome
    }

    // MARK: - Rename

    /// Renames a row. Renaming into a tombstone's name revives the tombstone with this row's
    /// value, and this row is retired (§7.1). Renaming back to `synced_name` is a revert of the
    /// name.
    ///
    /// - Parameter fingerprint: this row's current value fingerprinted for another row id, or
    ///   nil when its value is missing. Called only for a revival.
    public func rename(
        _ id: ConfigItemID,
        to name: String,
        fingerprint: (ConfigItemID) -> Data?
    ) throws(ItemEditError) -> ItemEditOutcomeModel {
        let normalized = try Self.validated(name)
        var draft = Draft(items: items)
        var row = try draft.existing(id)
        guard GitHubNameValidator.foldKey(normalized) != row.nameKey else { return draft.outcome }
        if let holder = draft.holder(scope: row.scope, kind: row.kind, name: normalized, excluding: id) {
            guard holder.isDeleted else { throw .nameTaken }
            var revived = holder
            revived.isDeleted = false
            revived.valueFingerprint = fingerprint(holder.id)
            draft.update(revived, value: .movedFrom(id))
            draft.retire(row)
            return draft.outcome
        }
        row.name = normalized
        draft.update(row, value: .unchanged)
        return draft.outcome
    }

    // MARK: - Revert

    /// Restores `value := synced value`, `name := synced_name`, and clears `is_deleted` and
    /// `force_push`. An unsynced row has nothing to return to and is removed.
    public func revert(_ id: ConfigItemID) throws(ItemEditError) -> ItemEditOutcomeModel {
        var draft = Draft(items: items)
        let row = try draft.existing(id)
        try draft.revert(row)
        return draft.outcome
    }

    /// Discard all (§7.1): reverts every row with a pending change.
    public func discardAll() throws(ItemEditError) -> ItemEditOutcomeModel {
        var draft = Draft(items: items)
        // Removals and reverts of renamed rows first, so restored names are free.
        let pending = items.filter(\.hasPendingChange).sorted { lhs, rhs in
            (lhs.isSynced ? 1 : 0, lhs.nameKey) < (rhs.isSynced ? 1 : 0, rhs.nameKey)
        }
        for row in pending {
            guard let current = draft.rowByID(row.id) else { continue }
            try draft.revert(current)
        }
        return draft.outcome
    }

    // MARK: - Fill (value-missing secrets, §7.1, §7.8)

    /// Fills a value-missing secret. By default the value is taken as what GitHub already has
    /// (`synced_* := same`, nothing pending); with `pushOnNextSync` it is pushed on the next
    /// Sync (`force_push := 1`).
    public func fill(
        _ id: ConfigItemID,
        pushOnNextSync: Bool,
        fingerprint: (ConfigItemID) -> Data
    ) throws(ItemEditError) -> ItemEditOutcomeModel {
        var draft = Draft(items: items)
        var row = try draft.existing(id)
        guard !row.hasValue, row.kind == .secret else { throw .valueNotMissing }
        let value = fingerprint(id)
        row.valueFingerprint = value
        guard row.isSynced, !pushOnNextSync else {
            // An unsynced row is a pending add anyway; a synced one is pushed as a modify.
            row.forcePush = row.isSynced
            draft.update(row, value: .newValue)
            return draft.outcome
        }
        row.syncedFingerprint = value
        row.hasSyncedValue = true
        draft.update(row, value: .newValueAsSynced)
        return draft.outcome
    }

    // MARK: - Convert / Move (D11)

    /// "Convert to variable / Move to…": a new row in the target kind and scope with this
    /// row's value, and this row is retired. The caller confirms secret→variable (§5.13).
    ///
    /// - Parameter fingerprint: this row's current value fingerprinted for the new row id, or
    ///   nil when its value is missing.
    public func move(
        _ id: ConfigItemID,
        kind: ConfigKind,
        scope: ConfigScope,
        newID: ConfigItemID = ConfigItemID(),
        fingerprint: (ConfigItemID) -> Data?
    ) throws(ItemEditError) -> ItemEditOutcomeModel {
        var draft = Draft(items: items)
        let row = try draft.existing(id)
        guard row.kind != kind || row.scope != scope else { return draft.outcome }
        if let holder = draft.holder(scope: scope, kind: kind, name: row.name, excluding: nil) {
            guard holder.isDeleted else { throw .nameTaken }
            var revived = holder
            revived.isDeleted = false
            revived.valueFingerprint = fingerprint(holder.id)
            draft.update(revived, value: .movedFrom(id))
        } else {
            let moved = ConfigItemSnapshotModel(
                id: newID,
                scope: scope,
                kind: kind,
                name: row.name,
                valueFingerprint: fingerprint(newID),
                provenance: row.provenance
            )
            draft.insert(moved, value: .movedFrom(id))
        }
        draft.retire(row)
        return draft.outcome
    }

    private static func validated(_ name: String) throws(ItemEditError) -> String {
        do {
            return try GitHubNameValidator.validate(name)
        } catch {
            throw .invalidName(error)
        }
    }
}

/// Mutable working copy of the rows during one edit.
private struct Draft {
    private(set) var items: [ConfigItemSnapshotModel]
    private(set) var mutations: [ItemMutationModel] = []

    init(items: [ConfigItemSnapshotModel]) {
        self.items = items
    }

    var outcome: ItemEditOutcomeModel {
        ItemEditOutcomeModel(items: items, mutations: mutations)
    }

    func rowByID(_ id: ConfigItemID) -> ConfigItemSnapshotModel? {
        items.first { $0.id == id }
    }

    func existing(_ id: ConfigItemID) throws(ItemEditError) -> ConfigItemSnapshotModel {
        guard let row = rowByID(id) else { throw .itemNotFound }
        return row
    }

    /// The row of `scope` and `kind` whose name folds like `name` (the unique index).
    func holder(scope: ConfigScope, kind: ConfigKind, name: String, excluding: ConfigItemID?) -> ConfigItemSnapshotModel? {
        let key = GitHubNameValidator.foldKey(name)
        return items.first { $0.id != excluding && $0.scope == scope && $0.kind == kind && $0.nameKey == key }
    }

    mutating func insert(_ row: ConfigItemSnapshotModel, value: ItemValueSourceModel) {
        items.append(row)
        mutations.append(.insert(row, value: value))
    }

    mutating func update(_ row: ConfigItemSnapshotModel, value: ItemValueSourceModel) {
        guard let index = items.firstIndex(where: { $0.id == row.id }) else { return }
        items[index] = row
        // An inserted row stays an insert; merge consecutive updates of one row.
        if let previous = mutations.lastIndex(where: { $0.rowID == row.id }) {
            switch mutations[previous] {
            case .insert(_, let oldValue):
                mutations[previous] = .insert(row, value: Self.merged(oldValue, value))
                return
            case .update(_, let oldValue):
                mutations[previous] = .update(row, value: Self.merged(oldValue, value))
                return
            case .remove:
                break
            }
        }
        mutations.append(.update(row, value: value))
    }

    mutating func remove(_ id: ConfigItemID) {
        items.removeAll { $0.id == id }
        let wasInserted = mutations.contains {
            if case .insert(let row, _) = $0 { return row.id == id }
            return false
        }
        mutations.removeAll { $0.rowID == id }
        if !wasInserted {
            mutations.append(.remove(id))
        }
    }

    /// Delete semantics: unsynced → removed; synced → tombstone under its synced name when free.
    mutating func retire(_ row: ConfigItemSnapshotModel) {
        guard let syncedName = row.syncedName else {
            remove(row.id)
            return
        }
        var tombstone = row
        tombstone.isDeleted = true
        tombstone.forcePush = false
        if holder(scope: row.scope, kind: row.kind, name: syncedName, excluding: row.id) == nil {
            tombstone.name = syncedName
        }
        update(tombstone, value: .unchanged)
    }

    mutating func revert(_ row: ConfigItemSnapshotModel) throws(ItemEditError) {
        guard let syncedName = row.syncedName else {
            remove(row.id)
            return
        }
        if holder(scope: row.scope, kind: row.kind, name: syncedName, excluding: row.id) != nil {
            throw .nameTaken
        }
        guard row.hasSyncedValue || row.kind == .secret else { throw .nothingToRevert }
        var reverted = row
        reverted.name = syncedName
        reverted.isDeleted = false
        reverted.forcePush = false
        reverted.valueFingerprint = row.hasSyncedValue ? row.syncedFingerprint : nil
        update(reverted, value: .syncedValue)
    }

    private static func merged(_ old: ItemValueSourceModel, _ new: ItemValueSourceModel) -> ItemValueSourceModel {
        new == .unchanged ? old : new
    }
}

private extension ItemMutationModel {
    var rowID: ConfigItemID {
        switch self {
        case .insert(let row, _), .update(let row, _): row.id
        case .remove(let id): id
        }
    }
}
