import Foundation
import VaultCore

/// A derived change plus the reason it cannot run, before normalization.
struct ChangeCandidate: Sendable, Hashable {
    var change: ConfigChangeModel
    var blockReason: ChangeBlockReason?
}

/// The §7.1 normalization pass: one final operation per remote key.
///
/// - Items are grouped by `(scope fold key, kind, name fold key)`. A set plus a delete on the
///   same key becomes the set (now an update: `isNew = false`, because GitHub has the name),
///   and the delete is dropped.
/// - Environments are grouped by `name_key`. A delete plus a create (or a rename into the same
///   key) becomes the upsert (`isNew = false`, base policy from the deleted row); the deleted
///   row's synced items become item deletes in the surviving environment, which are then
///   normalized against its sets, so nothing the old environment held survives by accident.
/// - Invariant: no key is in both the upsert set and the delete set
///   (``invariantViolations(in:)`` is empty).
public enum ChangeSetNormalizer {
    /// Normalizes plain changes (all executable). Result in canonical order.
    public static func normalize(_ changes: [ConfigChangeModel]) -> [ConfigChangeModel] {
        normalize(candidates: changes.map { ChangeCandidate(change: $0, blockReason: nil) }).map(\.change)
    }

    /// Keys that break the invariant: upserted and deleted at once. Empty for every change
    /// set ``ChangeSetBuilder`` produces.
    public static func invariantViolations(
        in changeSet: ChangeSetModel
    ) -> (items: Set<RemoteItemKeyModel>, environments: Set<RemoteScopeKeyModel>) {
        (
            changeSet.upsertedItemKeys.intersection(changeSet.deletedItemKeys),
            changeSet.upsertedEnvironmentKeys.intersection(changeSet.deletedEnvironmentKeys)
        )
    }

    static func normalize(candidates: [ChangeCandidate]) -> [ChangeCandidate] {
        let ordered = candidates.sorted { $0.change < $1.change }
        let environmentPass = normalizeEnvironments(ordered)
        return normalizeItems(environmentPass).sorted { $0.change < $1.change }
    }

    // MARK: - Environments

    private static func normalizeEnvironments(_ candidates: [ChangeCandidate]) -> [ChangeCandidate] {
        var deletesByKey: [RemoteScopeKeyModel: ChangeCandidate] = [:]
        var writesByKey: [RemoteScopeKeyModel: ChangeCandidate] = [:]
        var reconcilesByKey: [RemoteScopeKeyModel: ChangeCandidate] = [:]
        var others: [ChangeCandidate] = []
        for candidate in candidates {
            let key = candidate.change.scope
            switch candidate.change.kind {
            case .deleteEnvironment:
                if deletesByKey[key] == nil { deletesByKey[key] = candidate }
            case .upsertEnvironment, .renameEnvironment:
                if writesByKey[key] == nil { writesByKey[key] = candidate }
            case .reconcileBranchPatterns:
                if reconcilesByKey[key] == nil { reconcilesByKey[key] = candidate }
            default:
                others.append(candidate)
            }
        }
        var result = others + Array(reconcilesByKey.values)
        for (key, write) in writesByKey {
            guard let delete = deletesByKey.removeValue(forKey: key),
                  case .deleteEnvironment(let deleted) = delete.change.operation
            else {
                result.append(write)
                continue
            }
            result.append(merged(write, replacing: deleted))
            result += impliedItemDeletes(of: deleted, repositoryID: delete.change.repositoryID)
        }
        result += deletesByKey.values
        return result
    }

    /// The surviving create or rename when it replaces a deleted environment of the same key.
    private static func merged(_ write: ChangeCandidate, replacing deleted: EnvironmentDeleteChangeModel) -> ChangeCandidate {
        guard case .upsertEnvironment(var upsert) = write.change.operation else { return write }
        upsert.isNew = false
        upsert.syncedPolicy = deleted.syncedPolicy
        upsert.name = deleted.name
        var result = write
        result.change.operation = .upsertEnvironment(upsert)
        return result
    }

    private static func impliedItemDeletes(of deleted: EnvironmentDeleteChangeModel, repositoryID: RepoID) -> [ChangeCandidate] {
        deleted.impliedItems.map { item in
            ChangeCandidate(
                change: ConfigChangeModel(
                    repositoryID: repositoryID,
                    operation: .deleteItem(ItemDeleteChangeModel(
                        itemID: item.itemID,
                        environmentID: deleted.environmentID,
                        environmentName: deleted.name,
                        kind: item.kind,
                        name: item.name,
                        reason: .removedWithEnvironment
                    ))
                ),
                blockReason: nil
            )
        }
    }

    // MARK: - Items

    private static func normalizeItems(_ candidates: [ChangeCandidate]) -> [ChangeCandidate] {
        var setsByKey: [RemoteItemKeyModel: [ChangeCandidate]] = [:]
        var deletesByKey: [RemoteItemKeyModel: [ChangeCandidate]] = [:]
        var keys: [RemoteItemKeyModel] = []
        var result: [ChangeCandidate] = []
        for candidate in candidates {
            switch candidate.change.operation {
            case .setItem(let set):
                if setsByKey[set.key] == nil, deletesByKey[set.key] == nil { keys.append(set.key) }
                setsByKey[set.key, default: []].append(candidate)
            case .deleteItem(let delete):
                if setsByKey[delete.key] == nil, deletesByKey[delete.key] == nil { keys.append(delete.key) }
                deletesByKey[delete.key, default: []].append(candidate)
            default:
                result.append(candidate)
            }
        }
        for key in keys {
            let sets = setsByKey[key] ?? []
            let deletes = deletesByKey[key] ?? []
            if let chosen = preferredSet(sets) {
                result.append(deletes.isEmpty ? chosen : asUpdate(chosen))
            } else if let delete = deletes.first {
                result.append(delete)
            }
        }
        return result
    }

    /// One set per key: an executable one before a blocked one, then canonical order.
    /// Two sets on one key cannot come from consistent rows (the unique index forbids two rows
    /// with one name); the choice only has to be deterministic.
    private static func preferredSet(_ sets: [ChangeCandidate]) -> ChangeCandidate? {
        sets.min { lhs, rhs in
            if (lhs.blockReason == nil) != (rhs.blockReason == nil) { return lhs.blockReason == nil }
            return (lhs.change.operation.itemID?.uuidString ?? "") < (rhs.change.operation.itemID?.uuidString ?? "")
        }
    }

    private static func asUpdate(_ candidate: ChangeCandidate) -> ChangeCandidate {
        guard case .setItem(var set) = candidate.change.operation else { return candidate }
        set.isNew = false
        var result = candidate
        result.change.operation = .setItem(set)
        return result
    }
}
