import Foundation
import VaultCore

/// What drifted (tasks/todo.md §7.7).
public enum DriftKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// `fp(remote value) != synced_fp`.
    case variableModified = "variable_modified"
    /// Listed `updatedAt != remote_updated_at`.
    case secretModified = "secret_modified"
    /// GitHub has an item with no local row (or only a never-synced local row: a conflict).
    case remoteAdded = "remote_added"
    /// A synced, non-tombstoned row is missing on GitHub.
    case remoteDeleted = "remote_deleted"
    /// GitHub has an environment with no local row (or only a never-synced one: a conflict).
    case environmentAdded = "environment_added"
    /// A synced, non-tombstoned environment is missing on GitHub.
    case environmentDeleted = "environment_deleted"
    /// The environment's branch policy differs from `synced_branch_policy` (D27: "an
    /// environment policy that differs" is routed to Drift review).
    case environmentPolicyModified = "environment_policy_modified"
}

/// One drift finding with both resolutions described as pure state effects.
public struct DriftModel: Sendable, Hashable, Identifiable {
    public var repositoryID: RepoID
    public var kind: DriftKind
    public var subject: DriftSubjectModel
    /// Changed remotely while also pending locally (§7.7 "Conflict").
    public var isConflict: Bool
    /// GitHub's `updatedAt` of the item or environment (alert copy: "changed on GitHub on …").
    public var remoteUpdatedAt: Date?
    public var keepLocal: DriftResolutionModel
    public var acceptGitHub: DriftResolutionModel

    public init(
        repositoryID: RepoID,
        kind: DriftKind,
        subject: DriftSubjectModel,
        isConflict: Bool,
        remoteUpdatedAt: Date?,
        keepLocal: DriftResolutionModel,
        acceptGitHub: DriftResolutionModel
    ) {
        self.repositoryID = repositoryID
        self.kind = kind
        self.subject = subject
        self.isConflict = isConflict
        self.remoteUpdatedAt = remoteUpdatedAt
        self.keepLocal = keepLocal
        self.acceptGitHub = acceptGitHub
    }

    /// `<kind>:<target journal key>`; unique within one detection run.
    public var id: String {
        kind.rawValue + SyncEngineConstants.changeIDSeparator + subject.target.journalKey
    }

    public func resolution(_ option: DriftResolutionOption) -> DriftResolutionModel {
        switch option {
        case .keepLocal: keepLocal
        case .acceptGitHub: acceptGitHub
        }
    }
}

/// The item or environment a drift is about.
public enum DriftSubjectModel: Sendable, Hashable {
    case item(DriftItemSubjectModel)
    case environment(DriftEnvironmentSubjectModel)

    public var target: ChangeTargetModel {
        switch self {
        case .item(let item): .item(item.key)
        case .environment(let environment): .environment(environment.key)
        }
    }
}

/// A drifted secret or variable.
public struct DriftItemSubjectModel: Sendable, Hashable {
    /// The remote key (for a local row, its `synced_name`, or its `name` when unsynced).
    public var key: RemoteItemKeyModel
    public var kind: ConfigKind
    /// The name to show (GitHub's for a remote item, otherwise the local `synced_name`/`name`).
    public var name: String
    /// The environment's display name; nil at repository level.
    public var environmentName: String?
    /// The local environment row; nil at repository level or for an unknown environment.
    public var environmentID: EnvironmentID?
    /// The local row involved, if any.
    public var itemID: ConfigItemID?

    public init(
        key: RemoteItemKeyModel,
        kind: ConfigKind,
        name: String,
        environmentName: String?,
        environmentID: EnvironmentID?,
        itemID: ConfigItemID?
    ) {
        self.key = key
        self.kind = kind
        self.name = name
        self.environmentName = environmentName
        self.environmentID = environmentID
        self.itemID = itemID
    }

    public var scope: ConfigScope {
        ConfigScope(environmentID: environmentID)
    }
}

/// A drifted environment.
public struct DriftEnvironmentSubjectModel: Sendable, Hashable {
    public var key: RemoteScopeKeyModel
    /// GitHub's name for a remote environment, otherwise the local `synced_name`.
    public var name: String
    /// The local environment row, if any.
    public var environmentID: EnvironmentID?
    /// GitHub's id when the environment exists remotely.
    public var githubID: Int64?
    /// The remote policy when the environment exists remotely.
    public var remotePolicy: BranchPolicyKind?
    /// Names of the items listed in a remote environment (shown with "environment added").
    public var remoteItemNames: [String]

    public init(
        key: RemoteScopeKeyModel,
        name: String,
        environmentID: EnvironmentID?,
        githubID: Int64?,
        remotePolicy: BranchPolicyKind?,
        remoteItemNames: [String] = []
    ) {
        self.key = key
        self.name = name
        self.environmentID = environmentID
        self.githubID = githubID
        self.remotePolicy = remotePolicy
        self.remoteItemNames = remoteItemNames
    }
}

/// The two §7.7 resolution columns.
public enum DriftResolutionOption: String, Sendable, Hashable, CaseIterable {
    case keepLocal
    case acceptGitHub
}

/// One resolution: the state effects VaultData applies (in order, in one transaction) and a
/// follow-up for the UI. Unavailable resolutions carry a reason and no effects.
public struct DriftResolutionModel: Sendable, Hashable {
    public var option: DriftResolutionOption
    public var effects: [DriftEffectModel]
    public var unavailableReason: DriftUnavailableReason?
    public var followUp: DriftFollowUpModel?

    public init(
        option: DriftResolutionOption,
        effects: [DriftEffectModel],
        unavailableReason: DriftUnavailableReason? = nil,
        followUp: DriftFollowUpModel? = nil
    ) {
        self.option = option
        self.effects = effects
        self.unavailableReason = unavailableReason
        self.followUp = followUp
    }

    /// An unavailable resolution.
    public static func unavailable(_ option: DriftResolutionOption, _ reason: DriftUnavailableReason) -> Self {
        DriftResolutionModel(option: option, effects: [], unavailableReason: reason)
    }

    public var isAvailable: Bool {
        unavailableReason == nil
    }
}

/// Why a resolution cannot be chosen.
public enum DriftUnavailableReason: String, Sendable, Hashable, CaseIterable {
    /// Keeping the local side needs the local secret value, which is missing.
    case valueMissing
    /// The remote environment has the name a pending local environment rename moves to; the
    /// user must change or revert that rename first.
    case conflictsWithPendingRename
}

/// What the UI does after applying a resolution.
public enum DriftFollowUpModel: Sendable, Hashable {
    /// Open the value editor in fill mode (§7.7 secret "Accept GitHub").
    case promptFillValue(ConfigItemID)
}

/// One state change of a drift resolution, described purely. VaultData applies it; values
/// come from the same listing the drift run used (variables) or are left missing (secrets).
public enum DriftEffectModel: Sendable, Hashable {
    // MARK: Items

    /// Variable "Keep local": `synced_fp := remoteFingerprint` and `synced_value_ct :=` the
    /// listed value sealed for this row; the local value stays, so the row becomes a pending
    /// modify (unless equal).
    case rebaseVariable(itemID: ConfigItemID, remoteFingerprint: Data)
    /// Variable "Accept GitHub": value and synced value := the listed value (`value_fp =
    /// synced_fp = remoteFingerprint`), `name := synced_name`, `is_deleted := 0`,
    /// `force_push := 0`.
    case adoptRemoteVariable(itemID: ConfigItemID, remoteFingerprint: Data)
    /// Secret "Keep local": `remote_updated_at := remoteUpdatedAt` (the acknowledged base, so
    /// D27 does not block the push) and, unless the row is a tombstone, `force_push := 1`.
    case rebaseSecret(itemID: ConfigItemID, remoteUpdatedAt: Date?, forcePush: Bool)
    /// Secret "Accept GitHub": `value_ct/value_fp := nil`, `synced_value_ct/synced_fp := nil`,
    /// `remote_updated_at := remoteUpdatedAt`, `name := synced_name`, `is_deleted := 0`,
    /// `force_push := 0`. Followed by "Enter new value" in fill mode.
    case clearSecretValue(itemID: ConfigItemID, remoteUpdatedAt: Date?)
    /// "Keep local" for a remote-only item: a new tombstone row (`synced_name := name`,
    /// `is_deleted := 1`, `remote_updated_at := remoteUpdatedAt`; a variable also gets
    /// `synced_fp` of the listed value under the new row id) so the next Sync deletes it.
    case createTombstone(DriftItemPlacementModel)
    /// "Accept GitHub" for a remote-only item: a new synced row, `provenance = github`; a
    /// variable with the listed value (value and synced), a secret value-missing.
    case importItem(DriftItemPlacementModel)
    /// Before adopting a remote item into a renamed synced row: a new tombstone row takes over
    /// the row's current remote identity (`synced_name`, `synced_value_ct`, `synced_fp`,
    /// `remote_updated_at`), and the row's synced fields are cleared, so the old name is still
    /// deleted on GitHub.
    case detachSyncedIdentity(itemID: ConfigItemID)
    /// Conflict "Keep local" for a never-synced row whose name exists on GitHub:
    /// `synced_name := remoteName`, `remote_updated_at := remoteUpdatedAt`; a variable gets
    /// `synced_fp := remoteFingerprint` (+ sealed synced value), a secret `force_push := 1`.
    /// The local value stays and is pushed as a modify.
    case adoptRemoteIdentity(itemID: ConfigItemID, remoteName: String, remoteUpdatedAt: Date?, remoteFingerprint: Data?)
    /// Conflict "Accept GitHub": as ``adoptRemoteIdentity(itemID:remoteName:remoteUpdatedAt:remoteFingerprint:)``
    /// but the row takes GitHub's state: a variable's value := the listed value, a secret's
    /// value is cleared (value-missing, then "Enter new value").
    case replaceWithRemote(itemID: ConfigItemID, remoteName: String, remoteUpdatedAt: Date?, remoteFingerprint: Data?)
    /// Remote deleted "Keep local": `synced_name := nil`, `synced_value_ct/synced_fp := nil`,
    /// `remote_updated_at := nil`, `force_push := 0` (pending add).
    case markItemUnsynced(itemID: ConfigItemID)
    /// Remote deleted "Accept GitHub": the row is removed.
    case deleteLocalItem(itemID: ConfigItemID)

    // MARK: Environments

    /// Environment added "Keep local": a new environment tombstone (`synced_name := name`,
    /// `github_env_id`, `is_deleted := 1`) so the next Sync deletes it on GitHub.
    case createEnvironmentTombstone(name: String, githubID: Int64)
    /// Environment added "Accept GitHub": import the environment (policy, patterns, foreign
    /// rules) and its items (variables with values, secrets value-missing, `provenance = github`).
    case importEnvironment(name: String, githubID: Int64, policy: BranchPolicyKind)
    /// Environment conflict with a never-synced local environment of the same fold key:
    /// `synced_name := remoteName`, `github_env_id := githubID`, `synced_branch_policy :=
    /// remotePolicy`; with `adoptPolicy` also `branch_policy := remotePolicy`. Items are
    /// compared by the next drift run.
    case adoptRemoteEnvironment(environmentID: EnvironmentID, remoteName: String, githubID: Int64, remotePolicy: BranchPolicyKind, adoptPolicy: Bool)
    /// Environment deleted "Keep local" (re-create): `synced_name`, `synced_branch_policy`,
    /// `github_env_id` and every pattern's `github_policy_id := nil`; every child item
    /// ``markItemUnsynced(itemID:)``; child tombstones and pattern tombstones are removed.
    case markEnvironmentUnsynced(environmentID: EnvironmentID)
    /// Environment deleted "Accept GitHub": the environment row and its children are removed.
    case deleteLocalEnvironment(environmentID: EnvironmentID)
    /// Policy "Keep local": `synced_branch_policy := remotePolicy` (the local policy becomes a
    /// pending upsert when it differs).
    case rebaseEnvironmentPolicy(environmentID: EnvironmentID, remotePolicy: BranchPolicyKind)
    /// Policy "Accept GitHub": `branch_policy := synced_branch_policy := remotePolicy`; for
    /// custom, the patterns are replaced by GitHub's (B5).
    case adoptRemoteEnvironmentPolicy(environmentID: EnvironmentID, remotePolicy: BranchPolicyKind)
}

/// Where a new row created by a drift resolution goes.
public struct DriftItemPlacementModel: Sendable, Hashable {
    /// The local environment, nil at repository level.
    public var environmentID: EnvironmentID?
    public var kind: ConfigKind
    /// GitHub's name.
    public var name: String
    public var remoteUpdatedAt: Date?

    public init(environmentID: EnvironmentID?, kind: ConfigKind, name: String, remoteUpdatedAt: Date?) {
        self.environmentID = environmentID
        self.kind = kind
        self.name = name
        self.remoteUpdatedAt = remoteUpdatedAt
    }

    public var scope: ConfigScope {
        ConfigScope(environmentID: environmentID)
    }
}

/// Names of items and environments our own sync deleted recently (per `sync_journal`, within
/// `Timeouts.recentDeletionSuppression`). GitHub may still list them for a while; they are
/// not reported as "remote added" (§7.7, D28).
public struct DriftSuppressionModel: Sendable, Hashable {
    public var deletedItems: Set<RemoteItemKeyModel>
    public var deletedEnvironments: Set<RemoteScopeKeyModel>

    public init(deletedItems: Set<RemoteItemKeyModel> = [], deletedEnvironments: Set<RemoteScopeKeyModel> = []) {
        self.deletedItems = deletedItems
        self.deletedEnvironments = deletedEnvironments
    }

    /// Builds the suppression from the `target_key` of succeeded delete rows
    /// (`SyncJournalStore.fetchSucceeded(repositoryID:commands:since:)`). Keys that are neither
    /// item nor environment keys are ignored.
    public init(journalTargetKeys: some Sequence<String>) {
        var items: Set<RemoteItemKeyModel> = []
        var environments: Set<RemoteScopeKeyModel> = []
        for key in journalTargetKeys {
            if let item = RemoteItemKeyModel(journalKey: key) {
                items.insert(item)
            } else if let environment = RemoteScopeKeyModel(environmentJournalKey: key) {
                environments.insert(environment)
            }
        }
        self.init(deletedItems: items, deletedEnvironments: environments)
    }

    /// No suppression.
    public static let none = DriftSuppressionModel()
}
