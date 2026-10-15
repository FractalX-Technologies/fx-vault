import Foundation
import VaultCore

/// One row change a sync outcome implies, described purely (tasks/todo.md §7.3, §7.4, §7.6).
/// VaultData applies a ``SyncCommitModel``'s effects in order, in one transaction, together with
/// its journal outcomes. Values never appear here: VaultData re-reads and re-seals them itself.
public enum SyncStateEffectModel: Sendable, Hashable {
    // MARK: Repository

    /// C1 confirmed by B2: `github_id`, the normalized name, visibility, `default_branch`,
    /// `has_admin`/`has_push`, `created_at_github`.
    case repositoryCreated(RepositoryCreatedEffectModel)
    /// An environment write failed because of the GitHub plan: set the clearable
    /// `is_env_plan_gated` hint (§7.4).
    case repositoryPlanGated(repositoryID: RepoID)

    // MARK: Environments

    /// C2 confirmed by B4: `synced_name`, `synced_branch_policy`, `github_env_id`,
    /// `foreign_rules_json` and `remote_updated_at`.
    case environmentSynced(EnvironmentSyncedEffectModel)
    /// A verified guided rename (§7.6 step 5): the row moves to its new remote identity and a
    /// **new tombstone row** holds the previous one (`name = synced_name = previousName`,
    /// `is_deleted = 1`, `github_env_id = previousGitHubID`, `synced_branch_policy =
    /// previousPolicy`, no children). Its DELETE is an ordinary pending deletion.
    case environmentRenamed(EnvironmentRenamedEffectModel)
    /// C9 confirmed: the tombstoned environment row and its children are removed.
    case environmentDeleted(environmentID: EnvironmentID)
    /// The policy left custom (§7.3 step 2): every pattern's `github_policy_id := NULL`, pattern
    /// tombstones removed.
    case patternsUnsynced(environmentID: EnvironmentID)
    /// C3 (or a fresh B5 match): `github_policy_id := githubPolicyID`.
    case patternSynced(environmentID: EnvironmentID, patternID: BranchPatternID, githubPolicyID: Int64)
    /// C4 for a tombstoned pattern: the pattern row is removed.
    case patternRemoved(environmentID: EnvironmentID, patternID: BranchPatternID)

    // MARK: Items

    /// `pre_write_updated_at := updatedAt` (§7.3 step 4: the listed `updatedAt` right before the
    /// write; nil when GitHub does not list the name).
    case itemPreWriteBaseline(itemID: ConfigItemID, updatedAt: Date?)
    /// C5/C7 exited 0 (``ItemPushedEffectModel``).
    case itemPushed(ItemPushedEffectModel)
    /// Verification matched (§7.3 step 6): `verify_state := 'verified'`,
    /// `remote_updated_at := remoteUpdatedAt`; a `share` provenance is confirmed (`local`).
    case itemVerified(itemID: ConfigItemID, remoteUpdatedAt: Date?)
    /// The pending-verification pass gave up after `Limits.pendingVerifyChecks` passes:
    /// `verify_state := 'verified'`; with `forcePush` (secrets) also `force_push := 1` and, when
    /// `pre_write_updated_at` is set, `remote_updated_at := pre_write_updated_at`. The write was
    /// checked against that base (D27, or the user's push request) and the verifier gives up only
    /// when nothing changed after it, so the re-push is not blocked by a GitHub change the
    /// pushed value already replaced.
    case itemVerificationExpired(itemID: ConfigItemID, forcePush: Bool)
    /// C6/C8 confirmed (``ItemDeletedEffectModel``).
    case itemDeleted(ItemDeletedEffectModel)
}

/// See ``SyncStateEffectModel/repositoryCreated(_:)``.
public struct RepositoryCreatedEffectModel: Sendable, Hashable {
    public var repositoryID: RepoID
    /// GraphQL node id from B2.
    public var githubID: String
    public var ownerLogin: String
    /// The name GitHub used (from C1's stdout URL, confirmed by B2).
    public var name: String
    public var visibility: RepoVisibility
    public var defaultBranch: String?
    public var hasAdmin: Bool
    public var hasPush: Bool
    public var createdAt: Date?

    public init(
        repositoryID: RepoID,
        githubID: String,
        ownerLogin: String,
        name: String,
        visibility: RepoVisibility,
        defaultBranch: String?,
        hasAdmin: Bool,
        hasPush: Bool,
        createdAt: Date?
    ) {
        self.repositoryID = repositoryID
        self.githubID = githubID
        self.ownerLogin = ownerLogin
        self.name = name
        self.visibility = visibility
        self.defaultBranch = defaultBranch
        self.hasAdmin = hasAdmin
        self.hasPush = hasPush
        self.createdAt = createdAt
    }
}

/// See ``SyncStateEffectModel/environmentSynced(_:)``.
public struct EnvironmentSyncedEffectModel: Sendable, Hashable {
    public var environmentID: EnvironmentID
    /// The name GitHub stores (`synced_name`).
    public var syncedName: String
    public var githubID: Int64
    public var policy: BranchPolicyKind
    public var foreignRulesJSON: String?
    public var remoteUpdatedAt: Date?

    public init(
        environmentID: EnvironmentID,
        syncedName: String,
        githubID: Int64,
        policy: BranchPolicyKind,
        foreignRulesJSON: String?,
        remoteUpdatedAt: Date?
    ) {
        self.environmentID = environmentID
        self.syncedName = syncedName
        self.githubID = githubID
        self.policy = policy
        self.foreignRulesJSON = foreignRulesJSON
        self.remoteUpdatedAt = remoteUpdatedAt
    }
}

/// See ``SyncStateEffectModel/environmentRenamed(_:)``.
public struct EnvironmentRenamedEffectModel: Sendable, Hashable {
    /// The new identity of the row.
    public var synced: EnvironmentSyncedEffectModel
    /// The identity the new tombstone row takes over.
    public var previousName: String
    public var previousGitHubID: Int64?
    public var previousPolicy: BranchPolicyKind?

    public init(
        synced: EnvironmentSyncedEffectModel,
        previousName: String,
        previousGitHubID: Int64?,
        previousPolicy: BranchPolicyKind?
    ) {
        self.synced = synced
        self.previousName = previousName
        self.previousGitHubID = previousGitHubID
        self.previousPolicy = previousPolicy
    }
}

/// A successful C5/C7 (§7.3 step 4, D32). VaultData, inside its write transaction:
///
/// 1. With ``detachedPreviousName`` (the set half of an item rename, §7.6 step 6): a **new
///    tombstone row** (same scope and kind, `name = synced_name = detachedPreviousName`,
///    `is_deleted = 1`, the row's current `synced_value_ct`/`synced_fp`/`remote_updated_at`)
///    takes over the previous remote identity, so the old name is still deleted on GitHub.
/// 2. `synced_name := syncedName`, `synced_fp := pushedFingerprint`, `force_push := 0`,
///    `verify_state := 'pending'`, `pre_write_updated_at := preWriteUpdatedAt`.
/// 3. When the row's `value_fp` still equals ``sourceFingerprint`` (the value was not edited
///    during the run): `synced_value_ct :=` the pushed bytes sealed for the row (the decrypted
///    value, normalized with `ValueNormalizer` when ``didNormalizeValue``); with
///    ``didNormalizeValue`` also `value_ct`/`value_fp :=` the normalized value and
///    ``pushedFingerprint`` (local == GitHub, D32). Otherwise `synced_value_ct := NULL`.
public struct ItemPushedEffectModel: Sendable, Hashable {
    public var itemID: ConfigItemID
    public var syncedName: String
    /// `value_fp` of the value that was read for the push.
    public var sourceFingerprint: Data
    /// Fingerprint of the bytes gh received (the normalized value, D32).
    public var pushedFingerprint: Data
    /// Trailing CR/LF were stripped before the push.
    public var didNormalizeValue: Bool
    public var preWriteUpdatedAt: Date?
    /// The previous `synced_name` of a renamed row.
    public var detachedPreviousName: String?

    public init(
        itemID: ConfigItemID,
        syncedName: String,
        sourceFingerprint: Data,
        pushedFingerprint: Data,
        didNormalizeValue: Bool,
        preWriteUpdatedAt: Date?,
        detachedPreviousName: String?
    ) {
        self.itemID = itemID
        self.syncedName = syncedName
        self.sourceFingerprint = sourceFingerprint
        self.pushedFingerprint = pushedFingerprint
        self.didNormalizeValue = didNormalizeValue
        self.preWriteUpdatedAt = preWriteUpdatedAt
        self.detachedPreviousName = detachedPreviousName
    }
}

/// A confirmed C6/C8 (exit 0, or a 404 confirmed by a re-list of the same scope). VaultData
/// removes the row ``itemID`` when it is a tombstone or belongs to a tombstoned environment;
/// otherwise (the delete half of an item rename) it removes the tombstone row in the same scope
/// whose `synced_name` folds to ``syncedName`` (created by
/// ``ItemPushedEffectModel/detachedPreviousName``).
public struct ItemDeletedEffectModel: Sendable, Hashable {
    public var itemID: ConfigItemID
    public var environmentID: EnvironmentID?
    public var kind: ConfigKind
    public var syncedName: String

    public init(itemID: ConfigItemID, environmentID: EnvironmentID?, kind: ConfigKind, syncedName: String) {
        self.itemID = itemID
        self.environmentID = environmentID
        self.kind = kind
        self.syncedName = syncedName
    }
}
