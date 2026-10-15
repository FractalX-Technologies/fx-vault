import Foundation
import VaultCore

/// Pure change derivation (tasks/todo.md §7.1): local rows in, normalized changes out. Uses
/// fingerprints and flags only; never decrypts (D11).
///
/// | Row state | Change |
/// |---|---|
/// | repo `github_id == nil` | `.createRepository` |
/// | env never synced, not deleted | `.upsertEnvironment(isNew: true)` (+ patterns when custom) |
/// | env `synced_name_key != name_key` | `.renameEnvironment` + a copy of every live item (§7.6) |
/// | env case-only rename | no change, a ``ChangeNoteModel`` |
/// | env `branch_policy != synced_branch_policy` | `.upsertEnvironment(isNew: false)` |
/// | custom policy with unsynced or deleted synced patterns | `.reconcileBranchPatterns` |
/// | env tombstone | `.deleteEnvironment(synced_name)`, items implied |
/// | item never synced, not deleted | `.set…(isNew: true)` |
/// | item `name != synced_name` | `.set…(name, isNew: true)` + `.delete…(synced_name)` |
/// | item synced, value present, fp changed or `force_push` | `.set…(isNew: false)` |
/// | item tombstone | `.delete…(synced_name)` |
/// | a secret change that needs a missing value | blocked `.valueMissing` |
/// | env rename with value-missing secrets | blocked `.renameNeedsValues` |
///
/// Rows whose environment is missing from the snapshot (impossible with the foreign keys) and
/// never-synced tombstones (removed by coalescing) produce nothing.
public enum ChangeSetBuilder {
    public static func build(_ snapshot: RepoSnapshotModel) -> ChangeSetModel {
        var derivation = Derivation(snapshot: snapshot)
        derivation.deriveRepository()
        derivation.deriveEnvironments()
        derivation.deriveItems()

        let normalized = ChangeSetNormalizer.normalize(candidates: derivation.candidates)
        let changeSet = ChangeSetModel(
            repository: snapshot.repository,
            changes: normalized.map(\.change),
            notes: derivation.notes
        )
        var reasons: [String: ChangeBlockReason] = [:]
        for candidate in normalized {
            if let reason = candidate.blockReason {
                reasons[candidate.change.id] = reason
            }
        }
        return changeSet.blocking(reasons)
    }
}

/// One derivation pass over a snapshot.
private struct Derivation {
    let snapshot: RepoSnapshotModel
    private(set) var candidates: [ChangeCandidate] = []
    private(set) var notes: [ChangeNoteModel] = []
    private let environmentsByID: [EnvironmentID: EnvironmentModel]

    init(snapshot: RepoSnapshotModel) {
        self.snapshot = snapshot
        environmentsByID = Dictionary(snapshot.environments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var repositoryID: RepoID {
        snapshot.repository.id
    }

    private mutating func append(_ operation: ConfigChangeOperation, blockedBy reason: ChangeBlockReason? = nil) {
        candidates.append(ChangeCandidate(
            change: ConfigChangeModel(repositoryID: repositoryID, operation: operation),
            blockReason: reason
        ))
    }

    // MARK: - Repository

    mutating func deriveRepository() {
        let repository = snapshot.repository
        guard !repository.existsOnGitHub else { return }
        append(.createRepository(RepositoryCreateChangeModel(
            ownerLogin: repository.ownerLogin,
            name: repository.name,
            visibility: repository.visibility,
            description: repository.description,
            spec: repository.createSpec
        )))
    }

    // MARK: - Environments

    mutating func deriveEnvironments() {
        for environment in snapshot.environments {
            if environment.isDeleted {
                deriveDeletedEnvironment(environment)
            } else if !environment.isSynced {
                append(.upsertEnvironment(EnvironmentUpsertChangeModel(
                    environmentID: environment.id,
                    name: environment.name,
                    policy: environment.branchPolicy,
                    syncedPolicy: nil,
                    isNew: true
                )))
                deriveReconcile(environment, remoteName: environment.name)
            } else if environment.hasPendingRename {
                deriveRename(environment)
            } else {
                deriveSyncedEnvironment(environment)
            }
        }
    }

    private mutating func deriveDeletedEnvironment(_ environment: EnvironmentModel) {
        guard let syncedName = environment.syncedName else { return }
        let implied = snapshot.items(in: .environment(environment.id)).compactMap { item in
            item.syncedName.map {
                EnvironmentDeleteChangeModel.ImpliedItemModel(itemID: item.id, kind: item.kind, name: $0)
            }
        }
        append(.deleteEnvironment(EnvironmentDeleteChangeModel(
            environmentID: environment.id,
            name: syncedName,
            githubID: environment.githubEnvID,
            syncedPolicy: environment.syncedBranchPolicy,
            impliedItems: implied
        )))
    }

    private mutating func deriveSyncedEnvironment(_ environment: EnvironmentModel) {
        guard let syncedName = environment.syncedName else { return }
        if environment.hasCaseOnlyRename {
            notes.append(.caseOnlyEnvironmentRename(
                environmentID: environment.id,
                syncedName: syncedName,
                name: environment.name
            ))
        }
        if environment.hasPendingPolicyChange {
            append(.upsertEnvironment(EnvironmentUpsertChangeModel(
                environmentID: environment.id,
                name: syncedName,
                policy: environment.branchPolicy,
                syncedPolicy: environment.syncedBranchPolicy,
                isNew: false
            )))
        }
        deriveReconcile(environment, remoteName: syncedName)
    }

    /// §7.6: the rename recreates the environment, so every live item is copied into it. A
    /// value-missing secret blocks the whole rename (§7.6 step 2, §7.8).
    private mutating func deriveRename(_ environment: EnvironmentModel) {
        guard let syncedName = environment.syncedName else { return }
        let liveItems = snapshot.items(in: .environment(environment.id))
            .filter { !$0.isDeleted }
            .sorted { $0.nameKey < $1.nameKey }
        let missing = liveItems.filter { !$0.hasValue }.map(\.name)
        append(
            .renameEnvironment(EnvironmentRenameChangeModel(
                environmentID: environment.id,
                fromName: syncedName,
                toName: environment.name,
                policy: environment.branchPolicy,
                fromGitHubID: environment.githubEnvID
            )),
            blockedBy: missing.isEmpty ? nil : .renameNeedsValues(missing)
        )
        for item in liveItems {
            append(
                .setItem(ItemSetChangeModel(
                    itemID: item.id,
                    environmentID: environment.id,
                    environmentName: environment.name,
                    kind: item.kind,
                    name: item.name,
                    isNew: true,
                    reason: .copiedForEnvironmentRename
                )),
                blockedBy: item.hasValue ? nil : .valueMissing
            )
        }
    }

    /// Unsynced desired patterns, or deleted patterns GitHub still has, while the policy is
    /// custom. Outside custom GitHub keeps no patterns (`github_policy_id` is reset, §7.3).
    private mutating func deriveReconcile(_ environment: EnvironmentModel, remoteName: String) {
        guard case .custom(let patterns) = environment.branchPolicy else { return }
        let desired = patterns.filter { !$0.isDeleted }
        let deleted = patterns.filter { $0.isDeleted && $0.isSynced }
        guard desired.contains(where: { !$0.isSynced }) || !deleted.isEmpty else { return }
        append(.reconcileBranchPatterns(BranchPatternsChangeModel(
            environmentID: environment.id,
            environmentName: remoteName,
            desired: desired,
            deleted: deleted
        )))
    }

    // MARK: - Items

    mutating func deriveItems() {
        for item in snapshot.items {
            switch placement(of: item) {
            case .repository: deriveItem(item, environmentName: nil)
            case .environment(let name): deriveItem(item, environmentName: name)
            case .implied: continue
            }
        }
    }

    /// Where a row's own changes are written.
    private enum ItemPlacement {
        case repository
        /// The remote environment name (`synced_name`, or the name of a new environment).
        case environment(String)
        /// Nothing on its own: the environment is deleted (items implied), being renamed (items
        /// copied by the rename) or missing.
        case implied
    }

    private func placement(of item: ConfigItemSnapshotModel) -> ItemPlacement {
        guard let environmentID = item.scope.environmentID else { return .repository }
        guard let environment = environmentsByID[environmentID],
              !environment.isDeleted,
              !environment.hasPendingRename
        else { return .implied }
        return .environment(environment.syncedName ?? environment.name)
    }

    private mutating func deriveItem(_ item: ConfigItemSnapshotModel, environmentName: String?) {
        let valueBlock: ChangeBlockReason? = item.hasValue ? nil : .valueMissing
        func set(isNew: Bool, reason: ItemSetChangeModel.Reason) -> ConfigChangeOperation {
            .setItem(ItemSetChangeModel(
                itemID: item.id,
                environmentID: item.scope.environmentID,
                environmentName: environmentName,
                kind: item.kind,
                name: item.name,
                isNew: isNew,
                reason: reason
            ))
        }
        func delete(_ name: String, reason: ItemDeleteChangeModel.Reason) -> ConfigChangeOperation {
            .deleteItem(ItemDeleteChangeModel(
                itemID: item.id,
                environmentID: item.scope.environmentID,
                environmentName: environmentName,
                kind: item.kind,
                name: name,
                reason: reason
            ))
        }

        guard let syncedName = item.syncedName else {
            if !item.isDeleted {
                append(set(isNew: true, reason: .added), blockedBy: valueBlock)
            }
            return
        }
        if item.isDeleted {
            append(delete(syncedName, reason: .deleted))
        } else if item.isRenamed {
            append(set(isNew: true, reason: .renamed(from: syncedName)), blockedBy: valueBlock)
            append(delete(syncedName, reason: .renamed(to: item.name)))
        } else if item.isValueChanged || item.forcePush {
            append(set(isNew: false, reason: item.forcePush ? .forcePushed : .modified), blockedBy: valueBlock)
        }
    }
}
