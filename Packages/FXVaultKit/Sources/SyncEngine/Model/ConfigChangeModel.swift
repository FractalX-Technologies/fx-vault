import Foundation
import VaultCore

/// The kind of one change (tasks/todo.md §7.1). The raw value is written to `sync_journal.op`.
public enum ConfigChangeKind: String, Sendable, Hashable, Codable, CaseIterable {
    case createRepository = "create_repository"
    case upsertEnvironment = "upsert_environment"
    case renameEnvironment = "rename_environment"
    case reconcileBranchPatterns = "reconcile_branch_patterns"
    case deleteEnvironment = "delete_environment"
    case setVariable = "set_variable"
    case setSecret = "set_secret"
    case deleteVariable = "delete_variable"
    case deleteSecret = "delete_secret"

    /// True for deletions on GitHub (they go through the §7.5 confirmation).
    public var isDeletion: Bool {
        switch self {
        case .deleteEnvironment, .deleteVariable, .deleteSecret: true
        default: false
        }
    }

    /// Canonical execution order (§7.3): repository, environments, patterns, item sets,
    /// item deletes, environment deletes. Variables before secrets inside a scope.
    var orderRank: Int {
        switch self {
        case .createRepository: 0
        case .upsertEnvironment, .renameEnvironment: 1
        case .reconcileBranchPatterns: 2
        case .setVariable: 3
        case .setSecret: 4
        case .deleteVariable: 5
        case .deleteSecret: 6
        case .deleteEnvironment: 7
        }
    }
}

/// One executable (or blocked) change of a repository, derived from local rows only
/// (§7.1: fingerprints and flags, never values).
public struct ConfigChangeModel: Sendable, Hashable, Identifiable, Comparable {
    public var repositoryID: RepoID
    public var operation: ConfigChangeOperation

    public init(repositoryID: RepoID, operation: ConfigChangeOperation) {
        self.repositoryID = repositoryID
        self.operation = operation
    }

    public var kind: ConfigChangeKind {
        operation.kind
    }

    public var target: ChangeTargetModel {
        operation.target
    }

    /// Unique within a normalized change set: `<kind>:<target journal key>`.
    public var id: String {
        kind.rawValue + SyncEngineConstants.changeIDSeparator + target.journalKey
    }

    /// The remote scope the change writes to (for an environment rename: the new name).
    public var scope: RemoteScopeKeyModel {
        target.scope
    }

    /// Canonical order: by kind rank, then scope, then target.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.kind.orderRank != rhs.kind.orderRank { return lhs.kind.orderRank < rhs.kind.orderRank }
        if lhs.scope != rhs.scope { return lhs.scope < rhs.scope }
        return lhs.target < rhs.target
    }
}

/// What a change does, with everything the planner needs and nothing secret.
public enum ConfigChangeOperation: Sendable, Hashable {
    /// `github_id == nil`: C1, then everything else in the repository.
    case createRepository(RepositoryCreateChangeModel)
    /// New environment, or a policy change of a synced one (C2).
    case upsertEnvironment(EnvironmentUpsertChangeModel)
    /// Guided recreate of a synced environment under a new name (§7.6).
    case renameEnvironment(EnvironmentRenameChangeModel)
    /// POST missing and DELETE extra patterns of a custom-policy environment (C3/C4).
    case reconcileBranchPatterns(BranchPatternsChangeModel)
    /// Tombstoned environment (C9). Its items are implied.
    case deleteEnvironment(EnvironmentDeleteChangeModel)
    /// C5 / C7 for one item.
    case setItem(ItemSetChangeModel)
    /// C6 / C8 for one item.
    case deleteItem(ItemDeleteChangeModel)

    public var kind: ConfigChangeKind {
        switch self {
        case .createRepository: .createRepository
        case .upsertEnvironment: .upsertEnvironment
        case .renameEnvironment: .renameEnvironment
        case .reconcileBranchPatterns: .reconcileBranchPatterns
        case .deleteEnvironment: .deleteEnvironment
        case .setItem(let change): change.kind == .secret ? .setSecret : .setVariable
        case .deleteItem(let change): change.kind == .secret ? .deleteSecret : .deleteVariable
        }
    }

    public var target: ChangeTargetModel {
        switch self {
        case .createRepository: .repository
        case .upsertEnvironment(let change): .environment(.environment(named: change.name))
        case .renameEnvironment(let change): .environment(.environment(named: change.toName))
        case .reconcileBranchPatterns(let change): .environment(.environment(named: change.environmentName))
        case .deleteEnvironment(let change): .environment(.environment(named: change.name))
        case .setItem(let change): .item(change.key)
        case .deleteItem(let change): .item(change.key)
        }
    }
}

extension ConfigChangeOperation {
    /// The item row of an item change; nil for other changes.
    public var itemID: ConfigItemID? {
        switch self {
        case .setItem(let set): set.itemID
        case .deleteItem(let delete): delete.itemID
        default: nil
        }
    }
}

/// `.createRepository(spec)`.
public struct RepositoryCreateChangeModel: Sendable, Hashable {
    public var ownerLogin: String
    public var name: String
    public var visibility: RepoVisibility
    public var description: String?
    /// Nil only for a malformed row; the planner then creates with defaults.
    public var spec: RepoCreateSpecModel?

    public init(
        ownerLogin: String,
        name: String,
        visibility: RepoVisibility,
        description: String?,
        spec: RepoCreateSpecModel?
    ) {
        self.ownerLogin = ownerLogin
        self.name = name
        self.visibility = visibility
        self.description = description
        self.spec = spec
    }
}

/// `.upsertEnvironment(name, policy, isNew)`.
public struct EnvironmentUpsertChangeModel: Sendable, Hashable {
    public var environmentID: EnvironmentID
    /// The name sent to GitHub: the local name when new, otherwise `synced_name` (GitHub keeps
    /// the stored case, §7.1 case-only rename).
    public var name: String
    /// The desired policy, with its pattern rows when custom.
    public var policy: DeploymentBranchPolicyModel
    /// `synced_branch_policy` before the change (nil when new). The D27 base.
    public var syncedPolicy: BranchPolicyKind?
    /// True when GitHub does not have the environment yet.
    public var isNew: Bool

    public init(
        environmentID: EnvironmentID,
        name: String,
        policy: DeploymentBranchPolicyModel,
        syncedPolicy: BranchPolicyKind?,
        isNew: Bool
    ) {
        self.environmentID = environmentID
        self.name = name
        self.policy = policy
        self.syncedPolicy = syncedPolicy
        self.isNew = isNew
    }
}

/// `.renameEnvironment(from:to:)` (§7.6). The environment's items are copied by the
/// ``ItemSetChangeModel/Reason/copiedForEnvironmentRename`` sets in the same change set; the
/// old environment is deleted later as an ordinary tombstone, never by this change.
public struct EnvironmentRenameChangeModel: Sendable, Hashable {
    public var environmentID: EnvironmentID
    /// `synced_name`: the environment GitHub has now.
    public var fromName: String
    /// The new name (a different fold key).
    public var toName: String
    public var policy: DeploymentBranchPolicyModel
    /// The old environment's `github_env_id`: abort without deleting when the new one has the
    /// same id (§7.6 step 4 guard).
    public var fromGitHubID: Int64?

    public init(
        environmentID: EnvironmentID,
        fromName: String,
        toName: String,
        policy: DeploymentBranchPolicyModel,
        fromGitHubID: Int64?
    ) {
        self.environmentID = environmentID
        self.fromName = fromName
        self.toName = toName
        self.policy = policy
        self.fromGitHubID = fromGitHubID
    }
}

/// `.reconcileBranchPatterns(env)`: the executor fetches B5 fresh, POSTs the missing desired
/// patterns and DELETEs the extras (§7.3 step 3).
public struct BranchPatternsChangeModel: Sendable, Hashable {
    public var environmentID: EnvironmentID
    /// The remote environment name.
    public var environmentName: String
    /// Non-tombstoned pattern rows.
    public var desired: [BranchPatternModel]
    /// Tombstoned pattern rows GitHub still has (with a policy id).
    public var deleted: [BranchPatternModel]

    public init(
        environmentID: EnvironmentID,
        environmentName: String,
        desired: [BranchPatternModel],
        deleted: [BranchPatternModel]
    ) {
        self.environmentID = environmentID
        self.environmentName = environmentName
        self.desired = desired
        self.deleted = deleted
    }
}

/// `.deleteEnvironment(syncedName)`.
public struct EnvironmentDeleteChangeModel: Sendable, Hashable {
    public var environmentID: EnvironmentID
    /// `synced_name`.
    public var name: String
    public var githubID: Int64?
    /// `synced_branch_policy` (becomes the base when normalization merges the delete into an
    /// upsert of the same fold key).
    public var syncedPolicy: BranchPolicyKind?
    /// Synced items of the environment (tombstones included), deleted with it. Normalization
    /// turns them into item deletes when the environment is recreated in the same change set.
    public var impliedItems: [ImpliedItemModel]

    public init(
        environmentID: EnvironmentID,
        name: String,
        githubID: Int64?,
        syncedPolicy: BranchPolicyKind?,
        impliedItems: [ImpliedItemModel]
    ) {
        self.environmentID = environmentID
        self.name = name
        self.githubID = githubID
        self.syncedPolicy = syncedPolicy
        self.impliedItems = impliedItems
    }

    /// One synced item of a deleted environment.
    public struct ImpliedItemModel: Sendable, Hashable {
        public var itemID: ConfigItemID
        public var kind: ConfigKind
        /// `synced_name`.
        public var name: String

        public init(itemID: ConfigItemID, kind: ConfigKind, name: String) {
            self.itemID = itemID
            self.kind = kind
            self.name = name
        }
    }
}

/// `.set…(name, isNew)`.
public struct ItemSetChangeModel: Sendable, Hashable {
    public var itemID: ConfigItemID
    /// The local environment row, nil at repository level.
    public var environmentID: EnvironmentID?
    /// The remote environment name passed as `--env`, nil at repository level.
    public var environmentName: String?
    public var kind: ConfigKind
    /// The name to set (the local name).
    public var name: String
    /// True when GitHub does not have this name yet (a new secret verifies by being listed;
    /// a new variable costs one write, an update two, §7.3).
    public var isNew: Bool
    public var reason: Reason

    public init(
        itemID: ConfigItemID,
        environmentID: EnvironmentID?,
        environmentName: String?,
        kind: ConfigKind,
        name: String,
        isNew: Bool,
        reason: Reason
    ) {
        self.itemID = itemID
        self.environmentID = environmentID
        self.environmentName = environmentName
        self.kind = kind
        self.name = name
        self.isNew = isNew
        self.reason = reason
    }

    public var scope: RemoteScopeKeyModel {
        environmentName.map(RemoteScopeKeyModel.environment(named:)) ?? .repository
    }

    public var key: RemoteItemKeyModel {
        RemoteItemKeyModel(scope: scope, kind: kind, name: name)
    }

    /// Why the item is set.
    public enum Reason: Sendable, Hashable {
        /// Never pushed.
        case added
        /// The new half of an item rename; `from` is deleted by its paired change.
        case renamed(from: String)
        /// The value fingerprint differs from the synced one.
        case modified
        /// `force_push` (drift "Keep local" or a failed verification).
        case forcePushed
        /// Copied into the new environment of a guided rename (§7.6). Counted with the rename.
        case copiedForEnvironmentRename
    }
}

/// `.delete…(synced_name)`.
public struct ItemDeleteChangeModel: Sendable, Hashable {
    public var itemID: ConfigItemID
    public var environmentID: EnvironmentID?
    public var environmentName: String?
    public var kind: ConfigKind
    /// `synced_name`.
    public var name: String
    public var reason: Reason

    public init(
        itemID: ConfigItemID,
        environmentID: EnvironmentID?,
        environmentName: String?,
        kind: ConfigKind,
        name: String,
        reason: Reason
    ) {
        self.itemID = itemID
        self.environmentID = environmentID
        self.environmentName = environmentName
        self.kind = kind
        self.name = name
        self.reason = reason
    }

    public var scope: RemoteScopeKeyModel {
        environmentName.map(RemoteScopeKeyModel.environment(named:)) ?? .repository
    }

    public var key: RemoteItemKeyModel {
        RemoteItemKeyModel(scope: scope, kind: kind, name: name)
    }

    /// Why the item is deleted.
    public enum Reason: Sendable, Hashable {
        /// Tombstone.
        case deleted
        /// The old half of an item rename; `to` is set by its paired change.
        case renamed(to: String)
        /// The item belonged to a deleted environment that is recreated under the same fold key
        /// in the same change set (§7.1 normalization).
        case removedWithEnvironment
    }
}
