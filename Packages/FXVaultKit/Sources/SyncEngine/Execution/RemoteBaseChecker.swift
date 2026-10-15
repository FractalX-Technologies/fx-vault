import Foundation
import GitHubKit
import VaultCore

/// Optimistic-concurrency rules (tasks/todo.md D27, §7.3): did the remote base of a change move
/// since the vault last saw it? Shared by ``SyncPreflight`` (every touched scope) and
/// ``SyncExecutor`` (each scope's re-list right before its writes), so both apply the same rule.
///
/// Items (compared with a fresh native re-list of their scope):
/// - modify / force push: the remote item is gone, a secret's `updatedAt` differs from
///   `remote_updated_at` (``DriftDetector/isSameTimestamp(_:_:)``), or a variable's
///   fingerprint differs from `synced_fp`. A push the user requested
///   (`force_push_requested_at`) is blocked only by a secret change made after the request
///   (``ConfigItemSnapshotModel/isSecretChangedOnGitHub(updatedAt:)``);
/// - add / the new half of a rename: the name already exists on GitHub;
/// - delete: the remote item exists and changed as above (a missing one is fine: the delete
///   then confirms with a re-list);
/// - copies of a guided rename (§7.6) are never blocked here: their environment is new;
/// - rows still `verify_state = pending` are never blocked: the remote change may be our own
///   unconfirmed write.
///
/// Environments (compared with a fresh B3): see ``environmentBaseMoved(_:remote:local:ownedTargetKeys:)``.
enum RemoteBaseChecker {
    /// True when the item change's base moved. `row` is the change's local row.
    static func itemBaseMoved(
        _ operation: ConfigChangeOperation,
        row: ConfigItemSnapshotModel?,
        listing: RemoteScopeListingModel
    ) -> Bool {
        switch operation {
        case .setItem(let set):
            let remote = listing.item(kind: set.kind, nameKey: set.key.nameKey)
            switch set.reason {
            case .copiedForEnvironmentRename:
                return false
            case .added, .renamed:
                return remote != nil
            case .modified, .forcePushed:
                guard let row, let remote else { return true }
                return baseMoved(row: row, remote: remote)
            }
        case .deleteItem(let delete):
            guard let row, let remote = listing.item(kind: delete.kind, nameKey: delete.key.nameKey) else {
                return false
            }
            return baseMoved(row: row, remote: remote)
        default:
            return false
        }
    }

    /// The synced row against its listed remote item.
    static func baseMoved(row: ConfigItemSnapshotModel, remote: RemoteItemModel) -> Bool {
        guard row.verifyState != .pending else { return false }
        switch remote {
        case .secret(let secret):
            return row.isSecretChangedOnGitHub(updatedAt: secret.updatedAt)
        case .variable(let variable):
            guard let fingerprint = variable.fingerprint(for: row.id) else { return true }
            return fingerprint != row.syncedFingerprint
        }
    }

    /// True when an environment-level change's base moved.
    ///
    /// - new environment: GitHub already has its fold key (unless the journal shows our own
    ///   earlier PUT of it, `ownedTargetKeys`);
    /// - policy change: the environment is gone, or GitHub's policy differs from
    ///   `synced_branch_policy`;
    /// - rename: the target exists (unless ours), or the source is gone;
    /// - pattern reconcile: the environment is gone, or its policy differs from
    ///   `synced_branch_policy`;
    /// - delete: GitHub has a *different* environment (another id) under the name. A missing one
    ///   is fine (the delete confirms with B3).
    static func environmentBaseMoved(
        _ operation: ConfigChangeOperation,
        remote: [RemoteScopeKeyModel: GHEnvironmentDTO],
        local: EnvironmentModel?,
        ownedTargetKeys: Set<String>
    ) -> Bool {
        switch operation {
        case .upsertEnvironment(let upsert):
            let key = RemoteScopeKeyModel.environment(named: upsert.name)
            if upsert.isNew {
                return remote[key] != nil && !ownedTargetKeys.contains(key.journalKey)
            }
            guard let found = remote[key] else { return true }
            return found.branchPolicyKind != upsert.syncedPolicy
        case .renameEnvironment(let rename):
            let target = RemoteScopeKeyModel.environment(named: rename.toName)
            let source = RemoteScopeKeyModel.environment(named: rename.fromName)
            if remote[target] != nil, !ownedTargetKeys.contains(target.journalKey) { return true }
            return remote[source] == nil
        case .reconcileBranchPatterns(let patterns):
            guard let found = remote[.environment(named: patterns.environmentName)] else { return true }
            guard let syncedPolicy = local?.syncedBranchPolicy else { return false }
            return found.branchPolicyKind != syncedPolicy
        case .deleteEnvironment(let delete):
            guard let found = remote[.environment(named: delete.name)], let githubID = delete.githubID else { return false }
            return found.id != githubID
        default:
            return false
        }
    }
}

/// Builds a ``RemoteScopeListingModel`` for one scope from fresh GitHubKit listings, with each
/// listed variable fingerprinted once for every given row whose `name` or `synced_name` folds to
/// it (row-bound fingerprints, §5.4). Wipes the listed values.
enum ScopeListingBuilder {
    static func build(
        secrets: [GHSecretDTO],
        variables: [GHVariableListingModel],
        rows: [ConfigItemSnapshotModel],
        values: any SyncValueProviding
    ) throws(SyncError) -> RemoteScopeListingModel {
        defer { variables.forEach { $0.wipe() } }
        var candidates: [String: [ConfigItemID]] = [:]
        for row in rows where row.kind == .variable {
            for key in Set([row.nameKey] + (row.syncedNameKey.map { [$0] } ?? [])) {
                candidates[key, default: []].append(row.id)
            }
        }
        var remoteVariables: [RemoteVariableModel] = []
        for listed in variables {
            var fingerprints: [ConfigItemID: Data] = [:]
            for rowID in candidates[GitHubNameValidator.foldKey(listed.name)] ?? [] {
                fingerprints[rowID] = try values.fingerprint(listed.value, rowID: rowID)
            }
            remoteVariables.append(RemoteVariableModel(name: listed.name, updatedAt: listed.updatedAt, fingerprints: fingerprints))
        }
        return RemoteScopeListingModel(
            secrets: secrets.map { RemoteSecretModel(name: $0.name, updatedAt: $0.updatedAt) },
            variables: remoteVariables
        )
    }
}
