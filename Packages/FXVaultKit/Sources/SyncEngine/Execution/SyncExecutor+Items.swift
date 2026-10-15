import Foundation
import GitHubKit
import VaultCore

/// Item steps (tasks/todo.md §7.3 steps 4, 5 and 6; D13, D27, D32).
extension SyncExecutor {
    // MARK: - Step 4 (+6): one scope's upserts and their verification

    func writeScope(_ step: ScopeStepModel, run: inout RepoRun) async throws(SyncError) {
        if let failure = run.failedScopes[step.scope] {
            skipRemaining(step.changes, reason: .dependencyFailed(changeID: failure))
            return
        }
        _ = try await writeItems(step, deferEffects: false, run: &run)
    }

    /// The outcome of ``writeItems(_:deferEffects:run:)``.
    struct ScopeWriteResult {
        /// Changes whose gh command ran.
        var attempted = 0
        /// Every change was written and verified.
        var allVerified = false
        /// Row effects not committed yet (``writeItems(_:deferEffects:run:)`` with `deferEffects`).
        var deferredEffects: [SyncStateEffectModel] = []
    }

    /// One written item awaiting verification.
    private struct PushedItem {
        let change: ConfigChangeModel
        let set: ItemSetChangeModel
        let entry: SyncJournalEntryID
        let effect: ItemPushedEffectModel
        /// The write's outcome is unknown (timeout after start, 5xx, network after retries).
        let isIndeterminate: Bool
    }

    /// Re-lists the scope, re-checks D27 and records `pre_write_updated_at`, writes variables then
    /// secrets (one gh command each, value on stdin, D32-normalized), then verifies.
    ///
    /// With `deferEffects` (a guided rename's copies) only journal outcomes are committed; the
    /// row effects are returned for the rename's two-fact commit, and outcomes of written
    /// changes are left to the caller.
    func writeItems(_ step: ScopeStepModel, deferEffects: Bool, run: inout RepoRun) async throws(SyncError) -> ScopeWriteResult {
        var result = ScopeWriteResult()
        let sets = step.changes.compactMap { change -> (ConfigChangeModel, ItemSetChangeModel)? in
            if case .setItem(let set) = change.operation { return (change, set) }
            return nil
        }
        let listing: RemoteScopeListingModel
        do {
            listing = try await listScope(step, kinds: Set(sets.map(\.1.kind)), run: run)
        } catch {
            switch error {
            case .github(let ghError):
                for (change, _) in sets { fail(change, .github(ghError)) }
                return result
            case .sync(let syncError):
                throw syncError
            }
        }

        var toWrite: [(ConfigChangeModel, ItemSetChangeModel)] = []
        var baselines: [ConfigItemID: Date?] = [:]
        for (change, set) in sets {
            if RemoteBaseChecker.itemBaseMoved(change.operation, row: run.rows[set.itemID], listing: listing) {
                finish(change, .blocked(.change(.remoteChanged)))
                continue
            }
            toWrite.append((change, set))
            if set.kind == .secret {
                baselines[set.itemID] = .some(listing.secret(nameKey: set.key.nameKey)?.updatedAt)
            }
        }
        if !deferEffects, !baselines.isEmpty {
            try persistence.commit(SyncCommitModel(effects: baselines.sorted { $0.key < $1.key }.map {
                .itemPreWriteBaseline(itemID: $0.key, updatedAt: $0.value)
            }))
        }

        var pushed: [PushedItem] = []
        var failedOrSkipped = sets.count - toWrite.count
        for (change, set) in toWrite {
            if let reason = checkStop() {
                finish(change, .skipped(.runStopped(reason)))
                failedOrSkipped += 1
                continue
            }
            started(change)
            result.attempted += 1
            do {
                if let item = try await push(change, set: set, baseline: baselines[set.itemID] ?? nil, step: step, deferEffects: deferEffects, run: &run) {
                    pushed.append(item)
                } else {
                    failedOrSkipped += 1
                }
            } catch {
                // The run stops (lock, persistence). What was written stays pending verification.
                if !deferEffects {
                    for item in pushed {
                        finish(item.change, item.isIndeterminate ? .failed(.indeterminate) : .succeeded(.pending))
                    }
                }
                throw error
            }
        }
        guard !pushed.isEmpty else {
            result.allVerified = failedOrSkipped == 0
            return result
        }

        let confirmed = checkStop() == nil ? try await verify(pushed, step: step, run: run) : [:]
        var effects: [SyncStateEffectModel] = []
        var verifiedChanges: [ConfigChangeModel] = []
        for item in pushed {
            guard let remoteUpdatedAt = confirmed[item.set.itemID] else {
                if item.isIndeterminate {
                    finish(item.change, .failed(.indeterminate))
                } else if !deferEffects {
                    finish(item.change, .succeeded(.pending))
                }
                continue
            }
            run.verifiedSets.insert(item.change.id)
            var itemEffects: [SyncStateEffectModel] = []
            if item.isIndeterminate {
                itemEffects.append(.itemPushed(item.effect))
            }
            itemEffects.append(.itemVerified(itemID: item.set.itemID, remoteUpdatedAt: remoteUpdatedAt))
            if deferEffects {
                if item.isIndeterminate {
                    try run.journal.finish(item.entry, run.journal.reconciled())
                } else {
                    itemEffects.insert(.itemPushed(item.effect), at: 0)
                }
                result.deferredEffects += itemEffects
            } else if item.isIndeterminate {
                try run.journal.finish(item.entry, run.journal.reconciled(), effects: itemEffects)
                finish(item.change, .succeeded(.verified))
            } else {
                effects += itemEffects
                verifiedChanges.append(item.change)
            }
        }
        if !effects.isEmpty {
            try persistence.commit(SyncCommitModel(effects: effects))
        }
        for change in verifiedChanges {
            finish(change, .succeeded(.verified))
        }
        result.allVerified = failedOrSkipped == 0 && pushed.allSatisfy { confirmed[$0.set.itemID] != nil }
        return result
    }

    /// One C5/C7. Returns the item to verify, or nil when it failed (outcome recorded).
    private func push(
        _ change: ConfigChangeModel,
        set: ItemSetChangeModel,
        baseline: Date?,
        step: ScopeStepModel,
        deferEffects: Bool,
        run: inout RepoRun
    ) async throws(SyncError) -> PushedItem? {
        guard let ref = run.ref else { return nil }
        guard let source = try values.value(of: set.itemID) else {
            finish(change, .failed(.valueMissing))
            return nil
        }
        let normalized: ValueNormalizer.NormalizedValue
        do {
            normalized = try ValueNormalizer.normalize(source.value)
        } catch {
            source.wipe()
            finish(change, .failed(.invalidValue(error)))
            return nil
        }
        source.wipe()
        let value = normalized.value
        defer { value.wipe() }
        let expected = try values.fingerprint(value, rowID: set.itemID)
        if normalized.didStripTrailingNewlines {
            warn(.valueNormalized(itemID: set.itemID, name: set.name))
        }
        let effect = ItemPushedEffectModel(
            itemID: set.itemID,
            syncedName: set.name,
            sourceFingerprint: source.fingerprint,
            pushedFingerprint: expected,
            didNormalizeValue: normalized.didStripTrailingNewlines,
            preWriteUpdatedAt: baseline,
            detachedPreviousName: { if case .renamed(let from) = set.reason { return from } else { return nil } }()
        )
        let entry = try run.journal.begin(
            change,
            command: .set(set.kind),
            preWriteUpdatedAt: baseline,
            push: SyncJournalPushModel(effect)
        )
        let scheduler = run.scheduler
        let environment = step.environmentName
        do {
            try await fresh(run) { () async throws(GHError) in
                switch set.kind {
                case .secret:
                    try await scheduler.setSecret(set.name, repo: ref, environment: environment, value: value)
                case .variable:
                    try await scheduler.setVariable(set.name, repo: ref, environment: environment, value: value, isUpdate: !set.isNew)
                }
            }
        } catch {
            if error.isIndeterminateOutcome {
                try run.journal.finish(entry, run.journal.failed(error))
                return PushedItem(change: change, set: set, entry: entry, effect: effect, isIndeterminate: true)
            }
            let effects: [SyncStateEffectModel] = error == .planGated && set.environmentName != nil
                ? [.repositoryPlanGated(repositoryID: run.repositoryID)]
                : []
            try run.journal.finish(entry, run.journal.failed(error), effects: effects)
            fail(change, .github(error))
            return nil
        }
        if deferEffects {
            try run.journal.finish(entry, run.journal.succeeded())
        } else {
            try run.journal.finish(entry, run.journal.succeeded(), effects: [.itemPushed(effect)])
        }
        return PushedItem(change: change, set: set, entry: entry, effect: effect, isIndeterminate: false)
    }

    /// Re-lists the scope every `Timeouts.verifyRetryInterval` until every item is confirmed or
    /// `Timeouts.verifyRetryWindow` passed. Returns the confirmed items with GitHub's `updatedAt`.
    private func verify(_ items: [PushedItem], step: ScopeStepModel, run: RepoRun) async throws(SyncError) -> [ConfigItemID: Date?] {
        var confirmed: [ConfigItemID: Date?] = [:]
        let start = clock.uptime
        let kinds = Set(items.map(\.set.kind))
        while true {
            reportVerifying(step.scope)
            do {
                let listing = try await listScope(step, kinds: kinds, run: run)
                for item in items where confirmed[item.set.itemID] == nil {
                    let nameKey = item.set.key.nameKey
                    switch item.set.kind {
                    case .secret:
                        let listed = listing.secret(nameKey: nameKey)
                        if WriteVerifier.isSecretVerified(listed: listed, preWriteUpdatedAt: item.effect.preWriteUpdatedAt) {
                            confirmed[item.set.itemID] = .some(listed?.updatedAt)
                        }
                    case .variable:
                        let listed = listing.variable(nameKey: nameKey)
                        if WriteVerifier.isVariableVerified(
                            listedFingerprint: listed?.fingerprint(for: item.set.itemID),
                            expected: item.effect.pushedFingerprint
                        ) {
                            confirmed[item.set.itemID] = .some(listed?.updatedAt)
                        }
                    }
                }
            } catch {
                if case .sync(let syncError) = error { throw syncError }
            }
            if confirmed.count == items.count || clock.uptime - start >= Timeouts.verifyRetryWindow || checkStop() != nil {
                return confirmed
            }
            do {
                try await sleep(for: Timeouts.verifyRetryInterval)
            } catch {
                return confirmed
            }
        }
    }

    // MARK: - Step 5: one scope's deletes

    /// C6/C8. The delete half of an item rename runs only when its set was verified in this run.
    /// A 404 (or an indeterminate outcome) counts as done only when a re-list of the same scope
    /// succeeds right after it and no longer shows the name.
    func deleteItems(_ step: ScopeStepModel, run: inout RepoRun) async throws(SyncError) {
        if let failure = run.failedScopes[step.scope] {
            skipRemaining(step.changes, reason: .dependencyFailed(changeID: failure))
            return
        }
        let deletes = step.changes.compactMap { change -> (ConfigChangeModel, ItemDeleteChangeModel)? in
            if case .deleteItem(let delete) = change.operation { return (change, delete) }
            return nil
        }
        var runnable: [(ConfigChangeModel, ItemDeleteChangeModel)] = []
        for (change, delete) in deletes {
            if case .renamed = delete.reason {
                let pair = run.plan.changes.first { candidate in
                    if case .setItem(let set) = candidate.operation { return set.itemID == delete.itemID }
                    return false
                }
                guard let pair, run.verifiedSets.contains(pair.id) else {
                    finish(change, .skipped(.pairNotVerified(changeID: pair?.id ?? change.id)))
                    continue
                }
            }
            runnable.append((change, delete))
        }
        guard !runnable.isEmpty else { return }
        let listing: RemoteScopeListingModel
        do {
            listing = try await listScope(step, kinds: Set(runnable.map(\.1.kind)), run: run)
        } catch {
            switch error {
            case .github(let ghError):
                for (change, _) in runnable { fail(change, .github(ghError)) }
                return
            case .sync(let syncError):
                throw syncError
            }
        }
        for (change, delete) in runnable {
            if RemoteBaseChecker.itemBaseMoved(change.operation, row: run.rows[delete.itemID], listing: listing) {
                finish(change, .blocked(.change(.remoteChanged)))
                continue
            }
            if let reason = checkStop() {
                finish(change, .skipped(.runStopped(reason)))
                continue
            }
            try await deleteItem(change, delete: delete, step: step, run: &run)
        }
    }

    private func deleteItem(
        _ change: ConfigChangeModel,
        delete: ItemDeleteChangeModel,
        step: ScopeStepModel,
        run: inout RepoRun
    ) async throws(SyncError) {
        guard let ref = run.ref else { return }
        started(change)
        let scheduler = run.scheduler
        let environment = step.environmentName
        let effect = SyncStateEffectModel.itemDeleted(ItemDeletedEffectModel(
            itemID: delete.itemID,
            environmentID: delete.environmentID,
            kind: delete.kind,
            syncedName: delete.name
        ))
        let entry = try run.journal.begin(change, command: .delete(delete.kind))
        let deleted = await attempt { () async throws(GHError) in
            switch delete.kind {
            case .secret: try await scheduler.deleteSecret(delete.name, repo: ref, environment: environment)
            case .variable: try await scheduler.deleteVariable(delete.name, repo: ref, environment: environment)
            }
        }
        guard case .failure(let error) = deleted else {
            try run.journal.finish(entry, run.journal.succeeded(), effects: [effect])
            finish(change, .succeeded(.notApplicable))
            return
        }
        guard error == .notFound || error.isIndeterminateOutcome else {
            try run.journal.finish(entry, run.journal.failed(error))
            fail(change, .github(error))
            return
        }
        if try await isGone(delete, step: step, run: run) {
            let outcome = error == .notFound ? run.journal.succeeded() : run.journal.reconciled()
            try run.journal.finish(entry, outcome, effects: [effect])
            finish(change, .succeeded(.notApplicable))
        } else {
            try run.journal.finish(entry, run.journal.failed(error))
            fail(change, error == .notFound ? .github(.notFound) : .indeterminate)
        }
    }

    /// True only when a re-list of the scope succeeds and does not show the name.
    private func isGone(_ delete: ItemDeleteChangeModel, step: ScopeStepModel, run: RepoRun) async throws(SyncError) -> Bool {
        do {
            let listing = try await listScope(step, kinds: [delete.kind], run: run)
            return listing.item(kind: delete.kind, nameKey: delete.key.nameKey) == nil
        } catch {
            if case .sync(let syncError) = error { throw syncError }
            return false
        }
    }

    // MARK: - Listing

    enum ScopeListingError: Error {
        case github(GHError)
        case sync(SyncError)
    }

    /// B6/B7 and B8/B9 for the kinds asked, fingerprinted for the step's rows.
    func listScope(_ step: ScopeStepModel, kinds: Set<ConfigKind>, run: RepoRun) async throws(ScopeListingError) -> RemoteScopeListingModel {
        guard let ref = run.ref else { throw .github(.notFound) }
        let scheduler = run.scheduler
        let environment = step.environmentName
        var secrets: [GHSecretDTO] = []
        var variables: [GHVariableListingModel] = []
        do {
            if kinds.contains(.secret) {
                secrets = try await fresh(run) { () async throws(GHError) -> [GHSecretDTO] in
                    try await scheduler.listSecrets(ref, environment: environment)
                }
            }
            if kinds.contains(.variable) {
                variables = try await fresh(run) { () async throws(GHError) -> [GHVariableListingModel] in
                    try await scheduler.listVariables(ref, environment: environment)
                }
            }
        } catch {
            throw .github(error)
        }
        let rows = step.changes.compactMap { $0.operation.itemID.flatMap { run.rows[$0] } }
        do {
            return try ScopeListingBuilder.build(secrets: secrets, variables: variables, rows: rows, values: values)
        } catch {
            throw .sync(error)
        }
    }
}
