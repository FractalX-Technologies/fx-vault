import Foundation
import GitHubKit
import VaultCore

/// Environment steps (tasks/todo.md §7.3 steps 2, 3 and 7; §7.6).
extension SyncExecutor {
    // MARK: - Step 2: environment create or policy change

    func upsertEnvironment(_ step: EnvironmentStepModel, run: inout RepoRun) async throws(SyncError) {
        let change = step.change
        started(change)
        let upsert = step.upsert
        switch try await putEnvironment(change, name: upsert.name, policy: upsert.policy, run: &run) {
        case .failed(let reason):
            run.failedScopes[change.scope] = change.id
            fail(change, reason)
        case .confirmed(let dto, let entry, let wasReconciled):
            var effects: [SyncStateEffectModel] = [.environmentSynced(Self.syncedEffect(upsert.environmentID, dto: dto))]
            if upsert.syncedPolicy == .custom, dto.branchPolicyKind != .custom {
                effects.append(.patternsUnsynced(environmentID: upsert.environmentID))
            }
            try run.journal.finish(entry, wasReconciled ? run.journal.reconciled() : run.journal.succeeded(), effects: effects)
            if !upsert.isNew, dto.foreignRulesJSON != step.storedForeignRulesJSON {
                warn(.foreignRulesChanged(environmentID: upsert.environmentID, name: dto.name))
            }
            finish(change, .succeeded(.notApplicable))
        }
    }

    enum EnvironmentPutOutcome {
        /// B4 shows the environment with the desired policy. The journal row is still open.
        case confirmed(GHEnvironmentDTO, entry: SyncJournalEntryID, wasReconciled: Bool)
        /// Journal outcome already written.
        case failed(SyncFailureReason)
    }

    /// C2, then B4 (a failed C2 may still have created the environment, so B4 decides). A 404
    /// that persists outside the freshRepo window while B2 succeeds is plan-gated (§8 C2).
    func putEnvironment(
        _ change: ConfigChangeModel,
        name: String,
        policy: DeploymentBranchPolicyModel,
        run: inout RepoRun
    ) async throws(SyncError) -> EnvironmentPutOutcome {
        guard let ref = run.ref else { return .failed(.github(.notFound)) }
        let scheduler = run.scheduler
        let entry = try run.journal.begin(change, command: .environmentPut)
        var putError: GHError?
        do {
            _ = try await fresh(run) { () async throws(GHError) -> GHEnvironmentDTO? in
                try await scheduler.upsertEnvironment(ref, named: name, branchPolicy: policy.gitHubFlags)
            }
        } catch {
            putError = error
        }
        if let error = putError, !error.mayHaveApplied {
            let classified = try await classifyEnvironmentFailure(error, run: run)
            var effects: [SyncStateEffectModel] = []
            if classified == .planGated { effects.append(.repositoryPlanGated(repositoryID: run.repositoryID)) }
            try run.journal.finish(entry, run.journal.failed(classified), effects: effects)
            return .failed(.github(classified))
        }
        let confirmation = await attempt { () async throws(GHError) -> GHEnvironmentDTO? in
            try await fresh(run) { () async throws(GHError) -> GHEnvironmentDTO? in
                try await scheduler.environment(ref, named: name)
            }
        }
        let reported: GHError
        switch confirmation {
        case .success(let dto?) where dto.branchPolicyKind == policy.kind:
            return .confirmed(dto, entry: entry, wasReconciled: putError != nil)
        case .success:
            reported = putError ?? .malformedOutput
        case .failure(let error):
            reported = putError ?? error
        }
        try run.journal.finish(entry, run.journal.failed(reported))
        return .failed(reported.isIndeterminateOutcome ? .indeterminate : .github(reported))
    }

    /// `.notFound` from an environment write outside the freshRepo window becomes `.planGated`
    /// when the repository itself is visible (B2).
    private func classifyEnvironmentFailure(_ error: GHError, run: RepoRun) async throws(SyncError) -> GHError {
        guard error == .notFound, !isFresh(run), let ref = run.ref else { return error }
        do {
            _ = try await run.scheduler.viewRepository(ref)
            return .planGated
        } catch {
            return .notFound
        }
    }

    static func syncedEffect(_ environmentID: EnvironmentID, dto: GHEnvironmentDTO) -> EnvironmentSyncedEffectModel {
        EnvironmentSyncedEffectModel(
            environmentID: environmentID,
            syncedName: dto.name,
            githubID: dto.id,
            policy: dto.branchPolicyKind,
            foreignRulesJSON: dto.foreignRulesJSON,
            remoteUpdatedAt: dto.updatedAt
        )
    }

    // MARK: - Step 3: pattern reconcile

    func reconcilePatterns(_ step: PatternStepModel, run: inout RepoRun) async throws(SyncError) {
        let change = step.change
        if let failure = run.failedScopes[change.scope] {
            finish(change, .skipped(.dependencyFailed(changeID: failure)))
            return
        }
        started(change)
        let outcome = try await syncPatterns(
            change,
            environmentID: step.patterns.environmentID,
            environmentName: step.patterns.environmentName,
            desired: step.patterns.desired,
            tombstones: step.patterns.deleted,
            deferEffects: false,
            run: &run
        )
        if let failure = outcome.failure {
            fail(change, failure)
        } else {
            finish(change, .succeeded(.notApplicable))
        }
    }

    struct PatternOutcome {
        var failure: SyncFailureReason?
        /// Pattern effects not committed yet (rename: committed with the two-fact commit).
        var effects: [SyncStateEffectModel] = []
    }

    /// Fresh B5, then C3 for each desired pattern GitHub lacks and C4 for each pattern GitHub has
    /// that is not desired (tombstoned rows included). A 200 (followed redirect) and a bare 303
    /// both count as success; a 303's id comes from a B5 re-list.
    func syncPatterns(
        _ change: ConfigChangeModel,
        environmentID: EnvironmentID,
        environmentName: String,
        desired: [BranchPatternModel],
        tombstones: [BranchPatternModel],
        deferEffects: Bool,
        run: inout RepoRun
    ) async throws(SyncError) -> PatternOutcome {
        guard let ref = run.ref else { return PatternOutcome(failure: .github(.notFound)) }
        let scheduler = run.scheduler
        var outcome = PatternOutcome()
        let remote: [GHBranchPolicyDTO]
        do {
            remote = try await listPatterns(ref, environment: environmentName, run: run)
        } catch {
            return PatternOutcome(failure: .github(error))
        }
        var needsRelist = false
        var pendingIDs: [BranchPatternModel] = []
        for pattern in desired {
            if let match = remote.first(where: { Self.isSame($0, pattern) }) {
                if pattern.githubPolicyID != match.id {
                    outcome.effects.append(.patternSynced(environmentID: environmentID, patternID: pattern.id, githubPolicyID: match.id))
                }
                continue
            }
            if let reason = checkStop() {
                return PatternOutcome(failure: .github(Self.error(for: reason)), effects: outcome.effects)
            }
            let entry = try run.journal.begin(change, command: .branchPolicyAdd, itemName: pattern.pattern)
            let added = await attempt { () async throws(GHError) -> GHBranchPolicyDTO? in
                try await fresh(run) { () async throws(GHError) -> GHBranchPolicyDTO? in
                    try await scheduler.addBranchPolicy(ref, environment: environmentName, pattern: pattern.pattern, type: pattern.type)
                }
            }
            switch added {
            case .success(let policy?):
                let effects: [SyncStateEffectModel] = [
                    .patternSynced(environmentID: environmentID, patternID: pattern.id, githubPolicyID: policy.id),
                ]
                try commitPattern(entry, effects: effects, deferEffects: deferEffects, outcome: &outcome, run: run)
            case .success(nil):
                needsRelist = true
                pendingIDs.append(pattern)
                try commitPattern(entry, effects: [], deferEffects: deferEffects, outcome: &outcome, run: run)
            case .failure(let error):
                // Observed live: a Free-plan private repository accepts the environment PUT but
                // answers C3 with a bare 404, so a 404 on a visible repository is plan-gated.
                let classified = try await classifyEnvironmentFailure(error, run: run)
                let effects: [SyncStateEffectModel] = classified == .planGated
                    ? [.repositoryPlanGated(repositoryID: run.repositoryID)]
                    : []
                try run.journal.finish(entry, run.journal.failed(classified), effects: effects)
                return PatternOutcome(failure: .github(classified), effects: outcome.effects)
            }
        }
        let desiredKeys = Set(desired.map { PatternKey(pattern: $0.pattern, type: $0.type) })
        for extra in remote where !desiredKeys.contains(PatternKey(pattern: extra.name, type: extra.type)) {
            if let reason = checkStop() {
                return PatternOutcome(failure: .github(Self.error(for: reason)), effects: outcome.effects)
            }
            let entry = try run.journal.begin(change, command: .branchPolicyDelete, itemName: extra.name)
            let deleted = await attempt { () async throws(GHError) in
                try await scheduler.deleteBranchPolicy(ref, environment: environmentName, policyID: extra.id)
            }
            if case .failure(let error) = deleted {
                try run.journal.finish(entry, run.journal.failed(error))
                return PatternOutcome(failure: .github(error), effects: outcome.effects)
            }
            let removed = tombstones.filter { $0.githubPolicyID == extra.id || Self.isSame(extra, $0) }
            try commitPattern(
                entry,
                effects: removed.map { .patternRemoved(environmentID: environmentID, patternID: $0.id) },
                deferEffects: deferEffects,
                outcome: &outcome,
                run: run
            )
        }
        // Tombstones GitHub no longer has are simply removed.
        let remoteIDs = Set(remote.map(\.id))
        for tombstone in tombstones where !remote.contains(where: { Self.isSame($0, tombstone) })
            && !(tombstone.githubPolicyID.map(remoteIDs.contains) ?? false) {
            outcome.effects.append(.patternRemoved(environmentID: environmentID, patternID: tombstone.id))
        }
        if needsRelist {
            let relisted = (try? await listPatterns(ref, environment: environmentName, run: run)) ?? []
            for pattern in pendingIDs {
                if let match = relisted.first(where: { Self.isSame($0, pattern) }) {
                    outcome.effects.append(.patternSynced(environmentID: environmentID, patternID: pattern.id, githubPolicyID: match.id))
                }
            }
        }
        if !deferEffects, !outcome.effects.isEmpty {
            try persistence.commit(SyncCommitModel(effects: outcome.effects))
            outcome.effects = []
        }
        return outcome
    }

    private struct PatternKey: Hashable {
        let pattern: String
        let type: BranchPatternType
    }

    private func commitPattern(
        _ entry: SyncJournalEntryID,
        effects: [SyncStateEffectModel],
        deferEffects: Bool,
        outcome: inout PatternOutcome,
        run: RepoRun
    ) throws(SyncError) {
        if deferEffects {
            outcome.effects += effects
            try run.journal.finish(entry, run.journal.succeeded())
        } else {
            try run.journal.finish(entry, run.journal.succeeded(), effects: effects)
        }
    }

    /// B5; a 404 means the environment has no custom policy yet, so no patterns (§8 B5).
    private func listPatterns(_ ref: GHRepoRef, environment: String, run: RepoRun) async throws(GHError) -> [GHBranchPolicyDTO] {
        let scheduler = run.scheduler
        do {
            return try await fresh(run) { () async throws(GHError) -> [GHBranchPolicyDTO] in
                try await scheduler.listBranchPolicies(ref, environment: environment)
            }
        } catch .notFound {
            return []
        }
    }

    private static func isSame(_ remote: GHBranchPolicyDTO, _ local: BranchPatternModel) -> Bool {
        remote.name == local.pattern && remote.type == local.type
    }

    static func error(for reason: SyncStopReason) -> GHError {
        switch reason {
        case .rateLimited: .rateLimited
        case .writeBudgetExhausted: .writeBudgetExhausted
        case .tokenRevoked: .tokenRevoked
        case .notAuthenticated: .notAuthenticated
        case .cancelled, .locked, .persistenceFailed: .cancelled
        }
    }

    // MARK: - §7.6 guided rename

    /// PUT the new environment, post its patterns, copy every item, verify, then commit the two
    /// facts. Aborts without touching the old environment when the new one has the old id, and
    /// keeps the old one whenever anything is not verified.
    func renameEnvironment(_ step: RenameStepModel, run: inout RepoRun) async throws(SyncError) {
        let change = step.change
        let rename = step.rename
        started(change)
        let dto: GHEnvironmentDTO
        let entry: SyncJournalEntryID
        switch try await putEnvironment(change, name: rename.toName, policy: rename.policy, run: &run) {
        case .failed(let reason):
            run.failedScopes[change.scope] = change.id
            fail(change, reason)
            skipRemaining(step.copies, reason: .dependencyFailed(changeID: change.id))
            return
        case .confirmed(let confirmed, let journalEntry, _):
            dto = confirmed
            entry = journalEntry
        }
        if let previousID = rename.fromGitHubID, dto.id == previousID {
            try run.journal.finish(entry, run.journal.failed(code: SyncExecutionConstants.renameTargetIsSourceErrorCode))
            run.failedScopes[change.scope] = change.id
            finish(change, .failed(.renameTargetIsSource))
            skipRemaining(step.copies, reason: .dependencyFailed(changeID: change.id))
            return
        }
        try run.journal.finish(entry, run.journal.succeeded())

        var effects: [SyncStateEffectModel] = []
        if case .custom = rename.policy {
            let patterns = try await syncPatterns(
                change,
                environmentID: rename.environmentID,
                environmentName: rename.toName,
                desired: rename.policy.activePatterns,
                tombstones: [],
                deferEffects: true,
                run: &run
            )
            if let failure = patterns.failure {
                run.failedScopes[change.scope] = change.id
                fail(change, failure)
                skipRemaining(step.copies, reason: .dependencyFailed(changeID: change.id))
                return
            }
            effects += patterns.effects
        }

        let scope = ScopeStepModel(
            scope: change.scope,
            environmentID: rename.environmentID,
            environmentName: rename.toName,
            changes: step.copies
        )
        let copies = try await writeItems(scope, deferEffects: true, run: &run)
        guard copies.allVerified, copies.attempted == step.copies.count else {
            run.failedScopes[change.scope] = change.id
            finish(change, .failed(.renameNotVerified))
            for copy in step.copies where !hasOutcome(copy) {
                finish(copy, copies.attempted == 0 ? .skipped(.dependencyFailed(changeID: change.id)) : .failed(.renameNotVerified))
            }
            return
        }
        effects.insert(.environmentRenamed(EnvironmentRenamedEffectModel(
            synced: Self.syncedEffect(rename.environmentID, dto: dto),
            previousName: rename.fromName,
            previousGitHubID: rename.fromGitHubID,
            previousPolicy: step.previousPolicy
        )), at: 0)
        try persistence.commit(SyncCommitModel(effects: effects + copies.deferredEffects))
        if dto.foreignRulesJSON != step.storedForeignRulesJSON {
            warn(.foreignRulesChanged(environmentID: rename.environmentID, name: dto.name))
        }
        for copy in step.copies {
            finish(copy, .succeeded(.verified))
        }
        finish(change, .succeeded(.verified))
    }

    // MARK: - Step 7: environment delete

    /// C9 of a tombstone. B3 first: a missing environment is already done; a different
    /// environment under the name (another id) is `remoteChanged`. A 404 counts as done only
    /// when a B3 right after it no longer shows the environment.
    func deleteEnvironment(_ change: ConfigChangeModel, delete: EnvironmentDeleteChangeModel, run: inout RepoRun) async throws(SyncError) {
        guard let ref = run.ref else { return }
        let scheduler = run.scheduler
        started(change)
        let key = RemoteScopeKeyModel.environment(named: delete.name)
        let listed: GHEnvironmentDTO?
        do {
            listed = try await findEnvironment(key, ref: ref, run: run)
        } catch {
            fail(change, .github(error))
            return
        }
        guard let listed else {
            try persistence.commit(SyncCommitModel(effects: [.environmentDeleted(environmentID: delete.environmentID)]))
            finish(change, .succeeded(.notApplicable))
            return
        }
        if let githubID = delete.githubID, listed.id != githubID {
            finish(change, .blocked(.change(.remoteChanged)))
            return
        }
        if let reason = checkStop() {
            finish(change, .skipped(.runStopped(reason)))
            return
        }
        let entry = try run.journal.begin(change, command: .environmentDelete)
        let deleted = await attempt { () async throws(GHError) in
            try await scheduler.deleteEnvironment(ref, named: listed.name)
        }
        let effect = SyncStateEffectModel.environmentDeleted(environmentID: delete.environmentID)
        guard case .failure(let error) = deleted else {
            try run.journal.finish(entry, run.journal.succeeded(), effects: [effect])
            finish(change, .succeeded(.notApplicable))
            return
        }
        guard error == .notFound || error.mayHaveApplied else {
            try run.journal.finish(entry, run.journal.failed(error))
            fail(change, .github(error))
            return
        }
        let relisted = await attempt { () async throws(GHError) -> GHEnvironmentDTO? in
            try await findEnvironment(key, ref: ref, run: run)
        }
        if case .success(nil) = relisted {
            let outcome = error == .notFound ? run.journal.succeeded() : run.journal.reconciled()
            try run.journal.finish(entry, outcome, effects: [effect])
            finish(change, .succeeded(.notApplicable))
        } else {
            try run.journal.finish(entry, run.journal.failed(error))
            fail(change, error == .notFound ? .github(.notFound) : .indeterminate)
        }
    }

    private func findEnvironment(_ key: RemoteScopeKeyModel, ref: GHRepoRef, run: RepoRun) async throws(GHError) -> GHEnvironmentDTO? {
        let scheduler = run.scheduler
        let environments = try await fresh(run) { () async throws(GHError) -> [GHEnvironmentDTO] in
            try await scheduler.listEnvironments(ref)
        }
        return environments.first { RemoteScopeKeyModel.environment(named: $0.name) == key }
    }
}
