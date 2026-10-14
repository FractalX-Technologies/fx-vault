import Foundation

/// A GitHub environment of a repository (`environments` row, §6 `v3_config`).
///
/// The fold keys are computed from the names with ``EnvironmentNameValidator/foldKey(_:)`` so they
/// can never disagree with them; VaultStore persists the computed values in `name_key` columns.
public struct EnvironmentModel: Sendable, Hashable, Identifiable {
    public var id: EnvironmentID
    public var repositoryID: RepoID
    /// The desired (local) name, NFC.
    public var name: String
    /// The name GitHub has, or nil if the environment was never synced.
    public var syncedName: String?
    /// Tombstone: pending deletion on GitHub (only meaningful with ``syncedName``).
    public var isDeleted: Bool
    /// The desired branch policy, with its pattern rows when custom.
    public var branchPolicy: DeploymentBranchPolicyModel
    /// The policy GitHub has, or nil if never synced.
    public var syncedBranchPolicy: BranchPolicyKind?
    /// Reviewers, wait timer, app rules and admin bypass from GitHub, read-only JSON.
    public var foreignRulesJSON: String?
    /// GitHub's numeric environment id, once synced.
    public var githubEnvID: Int64?
    public var remoteUpdatedAt: Date?
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: EnvironmentID = EnvironmentID(),
        repositoryID: RepoID,
        name: String,
        syncedName: String? = nil,
        isDeleted: Bool = false,
        branchPolicy: DeploymentBranchPolicyModel = .all,
        syncedBranchPolicy: BranchPolicyKind? = nil,
        foreignRulesJSON: String? = nil,
        githubEnvID: Int64? = nil,
        remoteUpdatedAt: Date? = nil,
        sortOrder: Int = 0,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.name = name
        self.syncedName = syncedName
        self.isDeleted = isDeleted
        self.branchPolicy = branchPolicy
        self.syncedBranchPolicy = syncedBranchPolicy
        self.foreignRulesJSON = foreignRulesJSON
        self.githubEnvID = githubEnvID
        self.remoteUpdatedAt = remoteUpdatedAt
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// `name_key`: NFC, lowercased (Unicode case fold).
    public var nameKey: String {
        EnvironmentNameValidator.foldKey(name)
    }

    /// `synced_name_key`, or nil if never synced.
    public var syncedNameKey: String? {
        syncedName.map(EnvironmentNameValidator.foldKey)
    }

    /// True once the environment exists on GitHub.
    public var isSynced: Bool {
        syncedName != nil
    }

    /// A synced environment whose name changed beyond case (a guided rename, §7.6).
    public var hasPendingRename: Bool {
        guard let syncedNameKey else { return false }
        return syncedNameKey != nameKey
    }

    /// A synced environment whose name changed only in case: local only, GitHub keeps its case.
    public var hasCaseOnlyRename: Bool {
        guard let syncedName, let syncedNameKey else { return false }
        return syncedNameKey == nameKey && syncedName != name
    }

    /// The policy differs from what GitHub has (or the environment was never synced).
    public var hasPendingPolicyChange: Bool {
        syncedBranchPolicy != branchPolicy.kind
    }
}
