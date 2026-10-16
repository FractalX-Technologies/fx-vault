import Foundation
import GitHubKit
import VaultCore

/// A change that will not run, with the reason.
public struct SyncBlockedChangeModel: Sendable, Hashable, Identifiable {
    public var change: ConfigChangeModel
    public var reason: SyncBlockReason

    public init(change: ConfigChangeModel, reason: SyncBlockReason) {
        self.change = change
        self.reason = reason
    }

    public var id: String {
        change.id
    }
}

/// The preflight of one repository (tasks/todo.md §7.3).
public struct RepoPreflightModel: Sendable, Hashable, Identifiable {
    /// The local snapshot after preflight's own bookkeeping (an adopted repository creation, the
    /// pending-verification pass). The planner and executor use this one.
    public var snapshot: RepoSnapshotModel
    /// The normalized change set with D27 `remoteChanged` blocks applied (feed it to
    /// ``ChangeSummaryBuilder`` for the §7.2 summary).
    public var changeSet: ChangeSetModel
    /// The changes that will run, canonical order.
    public var executable: [ConfigChangeModel]
    /// Every change that will not run: the change set's blocked changes plus preflight's own
    /// (capability, scopes, names, values, capacity, listing failures), dependents included.
    public var blocked: [SyncBlockedChangeModel]
    /// Changes in ``executable`` that delete something on GitHub (§7.5).
    public var deletions: [ConfigChangeModel]
    /// Combined size of the repository-level variable values after this run (D32-normalized
    /// local values of every live repository variable).
    public var repositoryVariableBytes: Int
    /// The gate of every shared scope this run touches (v0.6.0, S5).
    public var spaces: [SyncSpaceGateModel]

    public init(
        snapshot: RepoSnapshotModel,
        changeSet: ChangeSetModel,
        executable: [ConfigChangeModel],
        blocked: [SyncBlockedChangeModel],
        repositoryVariableBytes: Int = 0,
        spaces: [SyncSpaceGateModel] = []
    ) {
        self.snapshot = snapshot
        self.changeSet = changeSet
        self.executable = executable
        self.blocked = blocked
        self.repositoryVariableBytes = repositoryVariableBytes
        self.spaces = spaces
        deletions = executable.filter(\.kind.isDeletion)
    }

    /// True above `Limits.repoVariablesWarningBytes` (§7.3: GitHub passes at most 256 KB of
    /// organization plus repository variables to a workflow run). A warning, not a block.
    public var exceedsRepositoryVariablesSize: Bool {
        repositoryVariableBytes > Limits.repoVariablesWarningBytes
    }

    public var id: RepoID {
        snapshot.repository.id
    }

    /// Changes blocked because GitHub changed since the last check: "Review drift" (§7.4).
    public var remoteChanged: [SyncBlockedChangeModel] {
        blocked.filter(\.reason.isRemoteChanged)
    }
}

/// Everything the Sync sheet shows before the user confirms (§7.2, §7.3, §7.5).
public struct SyncPreflightModel: Sendable, Hashable {
    /// The `run_id` the preflight journaled its lookups under; the executor reuses it.
    public var runID: SyncRunID
    public var repositories: [RepoPreflightModel]
    /// FX Vault's own hourly write budget per account (local throttle, not GitHub's quota),
    /// keyed by the account login as given.
    public var writeBudgets: [String: WriteBudgetModel]
    /// Throttle cost of every executable change (a variable update costs 2, D12).
    public var estimatedWriteCost: Int

    public init(
        runID: SyncRunID,
        repositories: [RepoPreflightModel],
        writeBudgets: [String: WriteBudgetModel],
        estimatedWriteCost: Int
    ) {
        self.runID = runID
        self.repositories = repositories
        self.writeBudgets = writeBudgets
        self.estimatedWriteCost = estimatedWriteCost
    }

    /// Executable changes across repositories.
    public var executableCount: Int {
        repositories.map(\.executable.count).reduce(0, +)
    }

    /// "Review N deletions…" (§7.5).
    public var deletionCount: Int {
        repositories.map(\.deletions.count).reduce(0, +)
    }

    /// True when the run would need more than the remaining hourly budget of some account.
    public var exceedsWriteBudget: Bool {
        let remaining = writeBudgets.values.map { $0.limit - $0.used }.min() ?? Limits.writesPerHour
        return estimatedWriteCost > remaining
    }

    /// The §7.2 summary of the change sets. Blocks only preflight knows (capability, names,
    /// values, capacity) are in each repository's ``RepoPreflightModel/blocked`` instead.
    public var summary: ChangeSummaryModel {
        let used = writeBudgets.values.map(\.used).max()
        return ChangeSummaryBuilder.summarize(
            repositories.map(\.changeSet),
            writeBudget: used.map { WriteBudgetModel(used: $0) }
        )
    }
}

/// Moves changes to a blocked list with their reason, then every change that depends on a
/// blocked one (``ChangeSetModel`` dependency rules) with ``SyncBlockReason/dependsOn(changeID:)``.
enum BlockCascade {
    static func apply(
        _ reasons: [String: SyncBlockReason],
        to changes: [ConfigChangeModel]
    ) -> (executable: [ConfigChangeModel], blocked: [SyncBlockedChangeModel]) {
        var executable = changes
        var blocked: [SyncBlockedChangeModel] = []
        var queue: [ConfigChangeModel] = []
        for change in changes {
            guard let reason = reasons[change.id] else { continue }
            executable.removeAll { $0 == change }
            blocked.append(SyncBlockedChangeModel(change: change, reason: reason))
            queue.append(change)
        }
        while !queue.isEmpty {
            let source = queue.removeFirst()
            for dependent in ChangeSetModel.dependents(of: source, in: executable) {
                executable.removeAll { $0 == dependent }
                blocked.append(SyncBlockedChangeModel(change: dependent, reason: .dependsOn(changeID: source.id)))
                queue.append(dependent)
            }
        }
        return (executable, blocked)
    }
}
