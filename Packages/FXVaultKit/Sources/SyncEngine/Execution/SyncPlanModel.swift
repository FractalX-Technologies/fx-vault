import Foundation
import VaultCore

/// What a sync run executes (tasks/todo.md §7.3), per repository, in order.
public struct SyncPlanModel: Sendable, Hashable {
    /// The preflight's run id: the executor journals under it.
    public var runID: SyncRunID
    public var repositories: [RepoPlanModel]

    public init(runID: SyncRunID, repositories: [RepoPlanModel]) {
        self.runID = runID
        self.repositories = repositories
    }

    /// Changes the run will attempt.
    public var changeCount: Int {
        repositories.map(\.changes.count).reduce(0, +)
    }
}

/// One repository's steps.
public struct RepoPlanModel: Sendable, Hashable, Identifiable {
    /// The local snapshot from preflight (rows the executor reads bases and names from).
    public var snapshot: RepoSnapshotModel
    /// Execution order (§7.3 steps 1–7).
    public var steps: [SyncStepModel]
    /// Changes preflight blocked (reported as blocked, never run).
    public var blocked: [SyncBlockedChangeModel]
    /// Deletions left out because the user did not confirm them (§7.5).
    public var unconfirmedDeletions: [ConfigChangeModel]

    public init(
        snapshot: RepoSnapshotModel,
        steps: [SyncStepModel],
        blocked: [SyncBlockedChangeModel],
        unconfirmedDeletions: [ConfigChangeModel]
    ) {
        self.snapshot = snapshot
        self.steps = steps
        self.blocked = blocked
        self.unconfirmedDeletions = unconfirmedDeletions
    }

    public var id: RepoID {
        snapshot.repository.id
    }

    /// Every change the steps run, in step order.
    public var changes: [ConfigChangeModel] {
        steps.flatMap(\.changes)
    }
}

/// One step of a repository's run.
public enum SyncStepModel: Sendable, Hashable {
    /// Step 1: C1, then B2 (freshRepo window starts).
    case createRepository(change: ConfigChangeModel, request: RepositoryCreateChangeModel)
    /// Step 2: C2, then B4.
    case upsertEnvironment(EnvironmentStepModel)
    /// Step 3: fresh B5, C3 for the missing patterns, C4 for the extras.
    case reconcilePatterns(PatternStepModel)
    /// §7.6: C2 for the new name, its patterns, every item copied (C7/C5), verification, then
    /// the two-fact commit. The old environment is deleted later as an ordinary tombstone.
    case renameEnvironment(RenameStepModel)
    /// Step 4 (+6): re-list the scope, D27 re-check, variable then secret upserts, verification.
    case writeScope(ScopeStepModel)
    /// Step 5: item deletes of one scope (a 404 counts only after a re-list confirms it).
    case deleteItems(ScopeStepModel)
    /// Step 7: C9 of a tombstoned environment.
    case deleteEnvironment(change: ConfigChangeModel, delete: EnvironmentDeleteChangeModel)

    /// The changes the step runs.
    public var changes: [ConfigChangeModel] {
        switch self {
        case .createRepository(let change, _): [change]
        case .upsertEnvironment(let step): [step.change]
        case .reconcilePatterns(let step): [step.change]
        case .renameEnvironment(let step): [step.change] + step.copies
        case .writeScope(let step), .deleteItems(let step): step.changes
        case .deleteEnvironment(let change, _): [change]
        }
    }
}

/// An environment create or policy change.
public struct EnvironmentStepModel: Sendable, Hashable {
    public var change: ConfigChangeModel
    public var upsert: EnvironmentUpsertChangeModel
    /// `foreign_rules_json` as stored (a changed value is reported as a warning).
    public var storedForeignRulesJSON: String?

    public init(change: ConfigChangeModel, upsert: EnvironmentUpsertChangeModel, storedForeignRulesJSON: String?) {
        self.change = change
        self.upsert = upsert
        self.storedForeignRulesJSON = storedForeignRulesJSON
    }
}

/// A branch-pattern reconciliation.
public struct PatternStepModel: Sendable, Hashable {
    public var change: ConfigChangeModel
    public var patterns: BranchPatternsChangeModel

    public init(change: ConfigChangeModel, patterns: BranchPatternsChangeModel) {
        self.change = change
        self.patterns = patterns
    }
}

/// A guided environment rename (§7.6).
public struct RenameStepModel: Sendable, Hashable {
    public var change: ConfigChangeModel
    public var rename: EnvironmentRenameChangeModel
    /// The item sets that copy every live item into the new environment.
    public var copies: [ConfigChangeModel]
    /// `synced_branch_policy` of the old environment (the new tombstone keeps it).
    public var previousPolicy: BranchPolicyKind?
    public var storedForeignRulesJSON: String?

    public init(
        change: ConfigChangeModel,
        rename: EnvironmentRenameChangeModel,
        copies: [ConfigChangeModel],
        previousPolicy: BranchPolicyKind?,
        storedForeignRulesJSON: String?
    ) {
        self.change = change
        self.rename = rename
        self.copies = copies
        self.previousPolicy = previousPolicy
        self.storedForeignRulesJSON = storedForeignRulesJSON
    }
}

/// The item changes of one remote scope.
public struct ScopeStepModel: Sendable, Hashable {
    public var scope: RemoteScopeKeyModel
    /// The local environment, nil at repository level.
    public var environmentID: EnvironmentID?
    /// The `--env` value, nil at repository level.
    public var environmentName: String?
    /// Variables first, then secrets (writeScope), or the deletes (deleteItems).
    public var changes: [ConfigChangeModel]

    public init(
        scope: RemoteScopeKeyModel,
        environmentID: EnvironmentID?,
        environmentName: String?,
        changes: [ConfigChangeModel]
    ) {
        self.scope = scope
        self.environmentID = environmentID
        self.environmentName = environmentName
        self.changes = changes
    }
}
