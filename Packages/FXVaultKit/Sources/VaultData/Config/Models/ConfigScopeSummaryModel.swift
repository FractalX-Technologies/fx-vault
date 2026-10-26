import VaultCore

/// One row of the scopes column (§10 `ScopeListView`): "Repository" or one environment, with
/// its pending dot and value-missing count.
public struct ConfigScopeSummaryModel: Sendable, Hashable, Identifiable {
    public let scope: ConfigScope
    /// The environment row; nil for the repository scope.
    public let environment: EnvironmentModel?
    /// Items that are not tombstones.
    public let itemCount: Int
    /// Secrets (not tombstones) whose value is missing locally (§7.8 chip count).
    public let valueMissingCount: Int
    /// True when the scope itself or one of its items has a local change to push.
    public let hasPendingChanges: Bool

    public init(
        scope: ConfigScope,
        environment: EnvironmentModel?,
        itemCount: Int,
        valueMissingCount: Int,
        hasPendingChanges: Bool
    ) {
        self.scope = scope
        self.environment = environment
        self.itemCount = itemCount
        self.valueMissingCount = valueMissingCount
        self.hasPendingChanges = hasPendingChanges
    }

    /// `repository` or the environment id.
    public var id: String {
        environment?.id.uuidString ?? ConfigScopeLevel.repository.rawValue
    }

    /// True for an environment tombstone (pending deletion on GitHub).
    public var isDeleted: Bool {
        environment?.isDeleted ?? false
    }
}

/// The pending and blocked counts of one repository (§7.1 Pending count).
public struct RepoPendingCountModel: Sendable, Hashable {
    /// Executable changes (`ChangeSetModel.pendingCount`).
    public let pending: Int
    /// Changes that cannot run (value missing, rename needing values).
    public let blocked: Int
    /// Live secrets without a value, at the repository level and in its live environments: the
    /// sidebar's count after the repository (1.0 D6d, board Main2-Repository).
    public let valueMissing: Int

    public init(pending: Int, blocked: Int, valueMissing: Int = 0) {
        self.pending = pending
        self.blocked = blocked
        self.valueMissing = valueMissing
    }
}

/// The "Sync N" label and dock badge input (§10 Toolbar): counts per repository and in total.
public struct PendingCountsModel: Sendable, Hashable {
    public let repositories: [RepoID: RepoPendingCountModel]

    public init(repositories: [RepoID: RepoPendingCountModel]) {
        self.repositories = repositories
    }

    /// Executable changes across every repository.
    public var total: Int {
        repositories.values.reduce(0) { $0 + $1.pending }
    }

    /// Blocked changes across every repository.
    public var blockedTotal: Int {
        repositories.values.reduce(0) { $0 + $1.blocked }
    }

    /// The counts of one repository (zero when it has none).
    public func counts(for repositoryID: RepoID) -> RepoPendingCountModel {
        repositories[repositoryID] ?? RepoPendingCountModel(pending: 0, blocked: 0)
    }

    public static let empty = PendingCountsModel(repositories: [:])
}
