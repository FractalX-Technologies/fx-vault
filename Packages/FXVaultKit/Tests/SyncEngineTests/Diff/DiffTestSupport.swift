import Foundation
import SyncEngine
import VaultCore

/// Fixture builders for the pure sync model. Synthetic names only (`owner-a`, `FXV_*`-style
/// item names), never real identifiers (tasks/lessons.md).
enum Fx {
    static let created = Date(timeIntervalSince1970: 1_790_000_000)
    static let repoID = RepoID()

    static func repo(onGitHub: Bool = true, spec: RepoCreateSpecModel? = nil) -> RepoModel {
        RepoModel(
            id: repoID,
            accountLogin: "user-a",
            githubID: onGitHub ? "R_fixture" : nil,
            ownerLogin: "owner-a",
            ownerType: .organization,
            name: "api",
            visibility: .private,
            hasAdmin: true,
            hasPush: true,
            origin: onGitHub ? .imported : .created,
            importedAt: created,
            createSpec: spec
        )
    }

    static func env(
        _ name: String,
        synced: String? = nil,
        deleted: Bool = false,
        policy: DeploymentBranchPolicyModel = .all,
        syncedPolicy: BranchPolicyKind? = nil,
        githubID: Int64? = nil,
        id: EnvironmentID = EnvironmentID()
    ) -> EnvironmentModel {
        EnvironmentModel(
            id: id,
            repositoryID: repoID,
            name: name,
            syncedName: synced,
            isDeleted: deleted,
            branchPolicy: policy,
            syncedBranchPolicy: syncedPolicy ?? (synced == nil ? nil : policy.kind),
            githubEnvID: githubID ?? (synced == nil ? nil : 1),
            createdAt: created,
            updatedAt: created
        )
    }

    /// A synced environment whose name and policy match GitHub.
    static func syncedEnv(_ name: String, policy: DeploymentBranchPolicyModel = .all, id: EnvironmentID = EnvironmentID()) -> EnvironmentModel {
        env(name, synced: name, policy: policy, id: id)
    }

    static let syncedPolicyID: Int64 = 7

    static func pattern(_ text: String, env: EnvironmentID, synced: Bool = false, deleted: Bool = false) -> BranchPatternModel {
        BranchPatternModel(
            environmentID: env,
            pattern: text,
            type: .branch,
            githubPolicyID: synced ? syncedPolicyID : nil,
            isDeleted: deleted
        )
    }

    /// Deterministic stand-in for the row-bound HMAC: the row id followed by the value.
    static func fp(_ value: String, row: ConfigItemID) -> Data {
        Data(row.uuidString.utf8) + Data(value.utf8)
    }

    static func fingerprint(_ value: SecretBytes, _ row: ConfigItemID) -> Data {
        Data(row.uuidString.utf8) + value.withUnsafeBytes { Data($0) }
    }

    /// An item row. `value` nil = value missing; `synced` = synced name with `syncedValue`.
    static func item(
        _ name: String,
        kind: ConfigKind = .secret,
        env: EnvironmentModel? = nil,
        value: String? = "v1",
        synced: String? = nil,
        syncedValue: String? = nil,
        deleted: Bool = false,
        forcePush: Bool = false,
        remoteUpdatedAt: Date? = nil,
        verify: VerifyState = .verified,
        id: ConfigItemID = ConfigItemID()
    ) -> ConfigItemSnapshotModel {
        let syncedFP = synced == nil ? nil : syncedValue.map { fp($0, row: id) }
        return ConfigItemSnapshotModel(
            id: id,
            scope: ConfigScope(environmentID: env?.id),
            kind: kind,
            name: name,
            valueFingerprint: value.map { fp($0, row: id) },
            isDeleted: deleted,
            syncedName: synced,
            hasSyncedValue: syncedFP != nil,
            syncedFingerprint: syncedFP,
            forcePush: forcePush,
            remoteUpdatedAt: remoteUpdatedAt,
            verifyState: verify
        )
    }

    /// A synced, unchanged item.
    static func syncedItem(
        _ name: String,
        kind: ConfigKind = .secret,
        env: EnvironmentModel? = nil,
        value: String? = "v1",
        remoteUpdatedAt: Date? = nil,
        verify: VerifyState = .verified,
        id: ConfigItemID = ConfigItemID()
    ) -> ConfigItemSnapshotModel {
        item(
            name,
            kind: kind,
            env: env,
            value: value,
            synced: name,
            syncedValue: value,
            remoteUpdatedAt: remoteUpdatedAt,
            verify: verify,
            id: id
        )
    }

    static func snapshot(
        onGitHub: Bool = true,
        spec: RepoCreateSpecModel? = nil,
        environments: [EnvironmentModel] = [],
        items: [ConfigItemSnapshotModel] = []
    ) -> RepoSnapshotModel {
        RepoSnapshotModel(repository: repo(onGitHub: onGitHub, spec: spec), environments: environments, items: items)
    }
}

/// Compact, order-independent descriptions of changes for table assertions.
enum Describe {
    static func scope(_ name: String?) -> String {
        name.map { "env:\($0)" } ?? "repo"
    }

    static func change(_ change: ConfigChangeModel) -> String {
        switch change.operation {
        case .createRepository:
            return "create_repository"
        case .upsertEnvironment(let upsert):
            return "upsert_environment \(upsert.name) \(upsert.isNew ? "new" : "update") \(upsert.policy.kind.rawValue)"
        case .renameEnvironment(let rename):
            return "rename_environment \(rename.fromName)->\(rename.toName)"
        case .reconcileBranchPatterns(let reconcile):
            let desired = reconcile.desired.map(\.pattern).sorted().joined(separator: ",")
            let deleted = reconcile.deleted.map(\.pattern).sorted().joined(separator: ",")
            return "reconcile \(reconcile.environmentName) +[\(desired)] -[\(deleted)]"
        case .deleteEnvironment(let delete):
            return "delete_environment \(delete.name)"
        case .setItem(let set):
            let reason: String = switch set.reason {
            case .added: "added"
            case .renamed(let from): "renamed<-\(from)"
            case .modified: "modified"
            case .forcePushed: "force"
            case .copiedForEnvironmentRename: "copy"
            }
            return "\(change.kind.rawValue) \(scope(set.environmentName)) \(set.name) \(set.isNew ? "new" : "update") \(reason)"
        case .deleteItem(let delete):
            let reason: String = switch delete.reason {
            case .deleted: "deleted"
            case .renamed(let to): "renamed->\(to)"
            case .removedWithEnvironment: "with-env"
            }
            return "\(change.kind.rawValue) \(scope(delete.environmentName)) \(delete.name) \(reason)"
        }
    }

    static func blocked(_ entry: BlockedChangeModel) -> String {
        let reason: String = switch entry.reason {
        case .valueMissing: "valueMissing"
        case .renameNeedsValues(let names): "renameNeedsValues[\(names.joined(separator: ","))]"
        case .remoteChanged: "remoteChanged"
        case .dependsOn: "dependsOn"
        }
        return "\(change(entry.change)) ! \(reason)"
    }
}
