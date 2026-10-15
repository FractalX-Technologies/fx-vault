import Foundation
import VaultCore

/// Orders a preflight's executable changes into steps (tasks/todo.md §7.3):
///
/// 1. repository creation;
/// 2. environment creates and policy changes;
/// 3. pattern reconciliations;
/// 4. guided environment renames (PUT, patterns, copies, verification, two-fact commit, §7.6);
/// 5. item writes, one scope at a time (repository first): variables, then secrets, each scope
///    verified before the next;
/// 6. item deletes, one scope at a time;
/// 7. environment deletes.
///
/// Dependencies are enforced by the executor: a failed repository create skips the repository,
/// a failed environment PUT skips its patterns and items, a failed rename keeps the old
/// environment, and the delete half of an item rename runs only when its set was verified.
public enum SyncPlanner {
    /// Plans every repository. With `includeDeletions == false` (the user did not confirm §7.5)
    /// every deletion stays pending and is reported as skipped.
    public static func plan(_ preflight: SyncPreflightModel, includeDeletions: Bool = true) -> SyncPlanModel {
        SyncPlanModel(
            runID: preflight.runID,
            repositories: preflight.repositories.map { plan($0, includeDeletions: includeDeletions) }
        )
    }

    /// Plans one repository.
    public static func plan(_ repository: RepoPreflightModel, includeDeletions: Bool = true) -> RepoPlanModel {
        let snapshot = repository.snapshot
        let changes = repository.executable.sorted()
        let unconfirmed = includeDeletions ? [] : changes.filter(\.kind.isDeletion)
        let runnable = changes.filter { includeDeletions || !$0.kind.isDeletion }
        var steps: [SyncStepModel] = []

        for change in runnable {
            if case .createRepository(let request) = change.operation {
                steps.append(.createRepository(change: change, request: request))
            }
        }
        for change in runnable {
            if case .upsertEnvironment(let upsert) = change.operation {
                steps.append(.upsertEnvironment(EnvironmentStepModel(
                    change: change,
                    upsert: upsert,
                    storedForeignRulesJSON: snapshot.environment(upsert.environmentID)?.foreignRulesJSON
                )))
            }
        }
        for change in runnable {
            if case .reconcileBranchPatterns(let patterns) = change.operation {
                steps.append(.reconcilePatterns(PatternStepModel(change: change, patterns: patterns)))
            }
        }
        var renameScopes: Set<RemoteScopeKeyModel> = []
        for change in runnable {
            guard case .renameEnvironment(let rename) = change.operation else { continue }
            renameScopes.insert(change.scope)
            let environment = snapshot.environment(rename.environmentID)
            steps.append(.renameEnvironment(RenameStepModel(
                change: change,
                rename: rename,
                copies: runnable.filter { candidate in
                    guard case .setItem(let set) = candidate.operation else { return false }
                    return set.reason == .copiedForEnvironmentRename && candidate.scope == change.scope
                },
                previousPolicy: environment?.syncedBranchPolicy,
                storedForeignRulesJSON: environment?.foreignRulesJSON
            )))
        }

        let sets = runnable.filter { change in
            guard case .setItem(let set) = change.operation else { return false }
            return !(set.reason == .copiedForEnvironmentRename && renameScopes.contains(change.scope))
        }
        steps += scopeSteps(sets).map(SyncStepModel.writeScope)
        let deletes = runnable.filter { $0.kind == .deleteVariable || $0.kind == .deleteSecret }
        steps += scopeSteps(deletes).map(SyncStepModel.deleteItems)
        for change in runnable {
            if case .deleteEnvironment(let delete) = change.operation {
                steps.append(.deleteEnvironment(change: change, delete: delete))
            }
        }
        return RepoPlanModel(
            snapshot: snapshot,
            steps: steps,
            blocked: repository.blocked,
            unconfirmedDeletions: unconfirmed
        )
    }

    /// Groups item changes by remote scope (repository first), keeping canonical order inside
    /// each scope (variables before secrets).
    private static func scopeSteps(_ changes: [ConfigChangeModel]) -> [ScopeStepModel] {
        var order: [RemoteScopeKeyModel] = []
        var grouped: [RemoteScopeKeyModel: [ConfigChangeModel]] = [:]
        for change in changes {
            if grouped[change.scope] == nil { order.append(change.scope) }
            grouped[change.scope, default: []].append(change)
        }
        return order.sorted().compactMap { scope in
            guard let changes = grouped[scope], let first = changes.first else { return nil }
            let placement: (EnvironmentID?, String?) = switch first.operation {
            case .setItem(let set): (set.environmentID, set.environmentName)
            case .deleteItem(let delete): (delete.environmentID, delete.environmentName)
            default: (nil, nil)
            }
            return ScopeStepModel(
                scope: scope,
                environmentID: placement.0,
                environmentName: placement.1,
                changes: changes.sorted { lhs, rhs in
                    lhs.kind.orderRank != rhs.kind.orderRank ? lhs.kind.orderRank < rhs.kind.orderRank : lhs < rhs
                }
            )
        }
    }
}
