import Foundation
import VaultCore

/// Why a change cannot run (§7.1, §7.3, §7.6, §7.8).
public enum ChangeBlockReason: Sendable, Hashable {
    /// A secret change that needs the local value, which is missing (`value_ct IS NULL`).
    case valueMissing
    /// A synced environment rename while these secrets of it are value-missing (§7.6 step 2).
    case renameNeedsValues([String])
    /// The remote base moved since the last check (D27); routed to Drift review.
    case remoteChanged
    /// The change depends on the blocked change with this id (an item rename pair, a new
    /// environment's contents, or anything in a repository that cannot be created).
    case dependsOn(changeID: String)
}

/// A change that stays pending, with the reason.
public struct BlockedChangeModel: Sendable, Hashable, Identifiable {
    public var change: ConfigChangeModel
    public var reason: ChangeBlockReason

    public init(change: ConfigChangeModel, reason: ChangeBlockReason) {
        self.change = change
        self.reason = reason
    }

    public var id: String {
        change.id
    }
}

/// A fact about the local state that produces no change but is worth telling the user.
public enum ChangeNoteModel: Sendable, Hashable {
    /// A synced environment renamed only in case: local only, GitHub keeps `syncedName` (§7.1).
    case caseOnlyEnvironmentRename(environmentID: EnvironmentID, syncedName: String, name: String)
}

/// The normalized changes of one repository (§7.1): executable changes in canonical order,
/// blocked changes, and notes.
///
/// Invariant: no ``RemoteItemKeyModel`` or environment key is both upserted and deleted among
/// ``changes`` and ``blocked`` together (``ChangeSetNormalizer``).
public struct ChangeSetModel: Sendable, Hashable {
    public var repository: RepoModel
    /// Executable changes, canonical order.
    public private(set) var changes: [ConfigChangeModel]
    /// Changes that stay pending, canonical order.
    public private(set) var blocked: [BlockedChangeModel]
    public var notes: [ChangeNoteModel]

    public init(
        repository: RepoModel,
        changes: [ConfigChangeModel],
        blocked: [BlockedChangeModel] = [],
        notes: [ChangeNoteModel] = []
    ) {
        self.repository = repository
        self.changes = changes.sorted()
        self.blocked = blocked.sorted { $0.change < $1.change }
        self.notes = notes
    }

    /// Nothing to run and nothing blocked.
    public var isEmpty: Bool {
        changes.isEmpty && blocked.isEmpty
    }

    /// The "Sync N" count (§7.1 Pending count): executable changes, where an environment rename
    /// or delete counts as 1 (the items a rename copies are part of it) and a pattern
    /// reconciliation is part of its environment's create, policy change or rename.
    public var pendingCount: Int {
        let environmentWrites = Set(changes.compactMap { change -> RemoteScopeKeyModel? in
            switch change.kind {
            case .upsertEnvironment, .renameEnvironment: change.scope
            default: nil
            }
        })
        return changes.filter { change in
            switch change.operation {
            case .setItem(let set):
                set.reason != .copiedForEnvironmentRename
            case .reconcileBranchPatterns:
                !environmentWrites.contains(change.scope)
            default:
                true
            }
        }.count
    }

    /// Executable deletions (§7.5 "Review N deletions…").
    public var deletionCount: Int {
        changes.filter(\.kind.isDeletion).count
    }

    /// The executable change with `id`.
    public func change(id: String) -> ConfigChangeModel? {
        changes.first { $0.id == id }
    }

    /// Item keys set by any change (executable or blocked).
    public var upsertedItemKeys: Set<RemoteItemKeyModel> {
        Set(allChanges.compactMap { change in
            if case .setItem(let set) = change.operation { return set.key }
            return nil
        })
    }

    /// Item keys deleted by any change (executable or blocked).
    public var deletedItemKeys: Set<RemoteItemKeyModel> {
        Set(allChanges.compactMap { change in
            if case .deleteItem(let delete) = change.operation { return delete.key }
            return nil
        })
    }

    /// Environment keys created, updated or renamed into by any change.
    public var upsertedEnvironmentKeys: Set<RemoteScopeKeyModel> {
        Set(allChanges.filter { $0.kind == .upsertEnvironment || $0.kind == .renameEnvironment }.map(\.scope))
    }

    /// Environment keys deleted by any change.
    public var deletedEnvironmentKeys: Set<RemoteScopeKeyModel> {
        Set(allChanges.filter { $0.kind == .deleteEnvironment }.map(\.scope))
    }

    /// Executable and blocked changes together.
    public var allChanges: [ConfigChangeModel] {
        changes + blocked.map(\.change)
    }

    /// Moves the changes with `ids` to ``blocked`` with `reason`, plus every change that
    /// depends on them (see ``blocking(_:)``). Used by `SyncPreflight` for
    /// ``ChangeBlockReason/remoteChanged`` (D27).
    public func blocking(_ ids: Set<String>, reason: ChangeBlockReason) -> ChangeSetModel {
        blocking(Dictionary(uniqueKeysWithValues: ids.map { ($0, reason) }))
    }

    /// Moves each change named in `reasons` to ``blocked`` with its reason, then every change
    /// that depends on a blocked one, with ``ChangeBlockReason/dependsOn(changeID:)``:
    ///
    /// - either half of an item rename pair blocks the other half;
    /// - a new environment or a rename blocks every change in its scope;
    /// - a repository creation blocks everything.
    ///
    /// Own reasons win over dependency reasons. Unknown ids and already blocked changes are
    /// ignored.
    public func blocking(_ reasons: [String: ChangeBlockReason]) -> ChangeSetModel {
        var result = self
        let direct = changes.filter { reasons[$0.id] != nil }
        var queue: [ConfigChangeModel] = []
        for change in direct {
            guard let reason = reasons[change.id] else { continue }
            result.changes.removeAll { $0 == change }
            result.blocked.append(BlockedChangeModel(change: change, reason: reason))
            queue.append(change)
        }
        while !queue.isEmpty {
            let blockedChange = queue.removeFirst()
            for dependent in Self.dependents(of: blockedChange, in: result.changes) {
                result.changes.removeAll { $0 == dependent }
                result.blocked.append(BlockedChangeModel(change: dependent, reason: .dependsOn(changeID: blockedChange.id)))
                queue.append(dependent)
            }
        }
        result.blocked.sort { $0.change < $1.change }
        return result
    }

    /// Changes in `changes` that cannot run without `change`.
    static func dependents(of change: ConfigChangeModel, in changes: [ConfigChangeModel]) -> [ConfigChangeModel] {
        switch change.operation {
        case .createRepository:
            return changes.filter { $0 != change }
        case .upsertEnvironment(let upsert) where upsert.isNew:
            return changes.filter { $0 != change && $0.scope == change.scope && $0.kind != .deleteEnvironment }
        case .renameEnvironment:
            return changes.filter { $0 != change && $0.scope == change.scope && $0.kind != .deleteEnvironment }
        case .setItem(let set):
            guard case .renamed(let from) = set.reason else { return [] }
            let pairKey = RemoteItemKeyModel(scope: set.scope, kind: set.kind, name: from)
            return changes.filter { candidate in
                if case .deleteItem(let delete) = candidate.operation {
                    return delete.key == pairKey && delete.itemID == set.itemID
                }
                return false
            }
        case .deleteItem(let delete):
            guard case .renamed(let to) = delete.reason else { return [] }
            let pairKey = RemoteItemKeyModel(scope: delete.scope, kind: delete.kind, name: to)
            return changes.filter { candidate in
                if case .setItem(let set) = candidate.operation {
                    return set.key == pairKey && set.itemID == delete.itemID
                }
                return false
            }
        default:
            return []
        }
    }
}
