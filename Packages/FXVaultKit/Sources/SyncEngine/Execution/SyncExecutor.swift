import Foundation
import GitHubKit
import os
import VaultCore

/// Runs one ``SyncPlanModel`` (tasks/todo.md §7.3 steps 1–7, §7.4, §7.6, D12, D13, D28).
///
/// - One gh command per item, serial through the account's ``GHCommandScheduler`` (which adds
///   the throttle, the fixed rate-limit backoff, idempotent 5xx/network retries and the single
///   token refresh on 401). Values go to gh on stdin only and are wiped after each command.
/// - Every write is journaled `in_flight` first; its outcome and the row bookkeeping are
///   committed together right after (``SyncPersisting/commit(_:)``), so a failed item simply
///   stays pending.
/// - Each scope is re-listed right before its writes (D27 re-check, `pre_write_updated_at`) and
///   verified right after (``WriteVerifier``), retrying every `Timeouts.verifyRetryInterval` for
///   up to `Timeouts.verifyRetryWindow`; unconfirmed writes stay `verify_state = pending`.
/// - "Not found" for a repository created in this run is retried every
///   `Timeouts.freshRepoRetryInterval` for up to `Timeouts.freshRepoRetryWindow` while the
///   `Timeouts.freshRepoWindow` is open, and is never classified as plan-gated.
/// - Indeterminate outcomes (timeout after start, 5xx, network) are reconciled by re-listing;
///   `gh repo create` is never retried and is reconciled with B2 (``RepositoryAdoption``).
/// - ``cancel()`` stops after the command in flight: completed items stay synced, unverified ones
///   stay pending, the rest is skipped.
/// - Shared scopes (v0.6.0, S5): the space marker is claimed and re-read before a shared scope's
///   first write, and published after the repository's steps (``SyncSpaceCoordinating``).
///
/// An executor runs one plan; create a new one per run.
public actor SyncExecutor {
    /// Progress events; finishes after ``SyncProgressEventModel/finished(_:)``.
    public nonisolated let progress: AsyncStream<SyncProgressEventModel>

    let schedulers: SyncSchedulerRegistry
    let persistence: any SyncPersisting
    let values: any SyncValueProviding
    let clock: any VaultClock
    let spaces: (any SyncSpaceCoordinating)?
    let progressContinuation: AsyncStream<SyncProgressEventModel>.Continuation
    private let cancelRequested = OSAllocatedUnfairLock(initialState: false)
    private var hasStarted = false

    // Run state.
    private var outcomes: [String: SyncChangeOutcomeModel] = [:]
    private var plannedChangeIDs: Set<String> = []
    private(set) var stopReason: SyncStopReason?
    private var warnings: [SyncWarningModel] = []
    private var completedCount = 0
    private var totalCount = 0
    /// "What changed?" of the shared space versions this run publishes.
    private(set) var spaceReason: String?

    public init(
        schedulers: SyncSchedulerRegistry,
        persistence: any SyncPersisting,
        values: any SyncValueProviding,
        clock: any VaultClock,
        spaces: (any SyncSpaceCoordinating)? = nil
    ) {
        self.schedulers = schedulers
        self.persistence = persistence
        self.values = values
        self.clock = clock
        self.spaces = spaces
        (progress, progressContinuation) = AsyncStream.makeStream(of: SyncProgressEventModel.self)
    }

    /// Stops the run after the gh command in flight. Synchronous; callable from any thread
    /// (sleep, screen lock, the Cancel button).
    public nonisolated func cancel() {
        cancelRequested.withLock { $0 = true }
    }

    /// Runs `plan` and returns the §7.4 result. Throws only ``SyncError/alreadyRunning``; every
    /// other problem ends the run early with ``SyncResultModel/stopReason``.
    public func run(_ plan: SyncPlanModel) async throws(SyncError) -> SyncResultModel {
        guard !hasStarted else { throw .alreadyRunning }
        hasStarted = true
        totalCount = plan.changeCount
        spaceReason = plan.spaceReason
        plannedChangeIDs = Set(plan.repositories.flatMap { $0.changes.map(\.id) })
        progressContinuation.yield(.started(total: totalCount))

        var repositories: [RepoSyncResultModel] = []
        for repository in plan.repositories {
            for blocked in repository.blocked {
                outcomes[blocked.change.id] = .blocked(blocked.reason)
            }
            for deletion in repository.unconfirmedDeletions {
                outcomes[deletion.id] = .skipped(.deletionNotConfirmed)
            }
            await execute(repository, runID: plan.runID)
            let entries = (repository.blocked.map(\.change) + repository.unconfirmedDeletions + repository.changes)
                .sorted()
                .map { change in
                    SyncChangeResultModel(change: change, outcome: outcomes[change.id] ?? .skipped(.runStopped(stopReason ?? .cancelled)))
                }
            repositories.append(RepoSyncResultModel(
                repositoryID: repository.id,
                fullName: repository.snapshot.repository.fullName,
                entries: entries
            ))
        }
        let result = SyncResultModel(
            runID: plan.runID,
            repositories: repositories,
            stopReason: stopReason,
            warnings: warnings
        )
        progressContinuation.yield(.finished(result))
        progressContinuation.finish()
        SyncLog.sync.info(
            "sync run finished: \(result.succeeded.count, privacy: .public) succeeded, \(result.failed.count, privacy: .public) failed, stop=\(String(describing: result.stopReason), privacy: .public)"
        )
        return result
    }

    // MARK: - Repository

    /// Mutable state of one repository's run.
    struct RepoRun {
        let plan: RepoPlanModel
        let scheduler: GHCommandScheduler
        let journal: SyncJournalWriter
        /// The repository on GitHub; nil when its name is invalid.
        var ref: GHRepoRef?
        /// Why ``ref`` is nil.
        var refError: GHError?
        /// Uptime when the repository was created in this run (freshRepo window).
        var freshRepoStart: Duration?
        /// The failed change every remaining change of the repository depends on.
        var repositoryFailure: String?
        /// Scopes whose environment PUT (or rename) failed, with that change's id.
        var failedScopes: [RemoteScopeKeyModel: String] = [:]
        /// Item set changes verified in this run (the delete half of a rename needs it).
        var verifiedSets: Set<String> = []
        let rows: [ConfigItemID: ConfigItemSnapshotModel]
        /// Shared scopes claimed in this run, with their `--env` value, published after the
        /// repository's steps (S5).
        var claimedSpaces: [(gate: SyncSpaceGateModel, environmentName: String?)] = []
        /// Shared scopes whose claim failed or was lost: the outcome of their remaining changes.
        var lostSpaces: [ConfigScope: SyncChangeOutcomeModel] = [:]

        var repositoryID: RepoID {
            plan.snapshot.repository.id
        }
    }

    private func execute(_ plan: RepoPlanModel, runID: SyncRunID) async {
        let repository = plan.snapshot.repository
        guard !plan.steps.isEmpty else { return }
        guard let scheduler = schedulers.scheduler(for: repository.accountLogin) else {
            for change in plan.changes { finish(change, .failed(.github(.notAuthenticated))) }
            return
        }
        var run = RepoRun(
            plan: plan,
            scheduler: scheduler,
            journal: SyncJournalWriter(
                persistence: persistence,
                clock: clock,
                runID: runID,
                accountLogin: repository.accountLogin,
                repositoryID: repository.id
            ),
            rows: Dictionary(plan.snapshot.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        )
        do {
            run.ref = try GHRepoRef(owner: repository.ownerLogin, name: repository.name)
        } catch {
            run.refError = error
        }
        for step in plan.steps {
            if let reason = checkStop() {
                skipRemaining(step.changes, reason: .runStopped(reason))
                continue
            }
            do {
                if let lost = try await claimSharedScope(of: step, run: &run) {
                    for change in step.changes { finish(change, lost) }
                    continue
                }
                try await execute(step, run: &run)
            } catch {
                stop(.from(error))
                skipRemaining(step.changes, reason: .runStopped(.from(error)))
            }
        }
        await publishClaimedSpaces(run)
    }

    private func execute(_ step: SyncStepModel, run: inout RepoRun) async throws(SyncError) {
        if let failure = run.repositoryFailure {
            skipRemaining(step.changes, reason: .dependencyFailed(changeID: failure))
            return
        }
        guard run.ref != nil else {
            for change in step.changes {
                finish(change, .failed(.github(run.refError ?? .malformedOutput)))
            }
            return
        }
        switch step {
        case .createRepository(let change, let request):
            try await createRepository(change, request: request, run: &run)
        case .upsertEnvironment(let environment):
            try await upsertEnvironment(environment, run: &run)
        case .reconcilePatterns(let patterns):
            try await reconcilePatterns(patterns, run: &run)
        case .renameEnvironment(let rename):
            try await renameEnvironment(rename, run: &run)
        case .writeScope(let scope):
            try await writeScope(scope, run: &run)
        case .deleteItems(let scope):
            try await deleteItems(scope, run: &run)
        case .deleteEnvironment(let change, let delete):
            try await deleteEnvironment(change, delete: delete, run: &run)
        }
    }

    /// Step 1 (§7.3, §8 C1): create, read the normalized name from stdout, confirm with B2.
    private func createRepository(
        _ change: ConfigChangeModel,
        request: RepositoryCreateChangeModel,
        run: inout RepoRun
    ) async throws(SyncError) {
        guard let ref = run.ref else { return }
        started(change)
        let spec = request.spec
        let createRequest = GHRepoCreateRequest(
            repo: ref,
            visibility: request.visibility,
            description: request.description,
            addReadme: spec?.autoInit ?? false,
            gitignoreTemplate: spec?.gitignoreTemplate,
            licenseTemplate: spec?.licenseTemplate
        )
        let entry = try run.journal.begin(change, command: .repoCreate)
        let created: GHRepoRef
        do {
            created = try await run.scheduler.createRepository(createRequest)
        } catch {
            try await reconcileFailedCreate(change, request: request, entry: entry, error: error, run: &run)
            return
        }
        run.ref = created
        run.freshRepoStart = clock.uptime
        do {
            let dto = try await fresh(run) { () async throws(GHError) -> GHRepoDTO in
                try await run.scheduler.viewRepository(created)
            }
            try run.journal.finish(entry, run.journal.succeeded(), effects: [
                RepositoryAdoption.effect(repositoryID: run.repositoryID, dto: dto, fallbackName: created.name),
            ])
        } catch {
            try run.journal.finish(entry, run.journal.succeeded())
            warnings.append(.repositoryNotConfirmed(repositoryID: run.repositoryID, name: created.name))
        }
        if spec?.cloneAfter == true {
            warnings.append(.cloneRequested(repositoryID: run.repositoryID))
        }
        finish(change, .succeeded(.notApplicable))
    }

    /// C1 failed. A definitive failure fails the repository; an indeterminate one is reconciled
    /// with B2 and adopted only under ``RepositoryAdoption``'s rule (never a second create).
    private func reconcileFailedCreate(
        _ change: ConfigChangeModel,
        request: RepositoryCreateChangeModel,
        entry: SyncJournalEntryID,
        error: GHError,
        run: inout RepoRun
    ) async throws(SyncError) {
        guard error.isIndeterminateOutcome, let ref = run.ref else {
            try run.journal.finish(entry, run.journal.failed(error))
            fail(change, .github(error))
            run.repositoryFailure = change.id
            return
        }
        try run.journal.finish(entry, run.journal.failed(error))
        run.freshRepoStart = clock.uptime
        let dto: GHRepoDTO
        do {
            dto = try await fresh(run) { () async throws(GHError) -> GHRepoDTO in
                try await run.scheduler.viewRepository(ref)
            }
        } catch {
            finish(change, .failed(.indeterminate))
            run.repositoryFailure = change.id
            return
        }
        let history = try persistence.journalEntries(repositoryID: run.repositoryID, since: retentionStart)
        guard RepositoryAdoption.journalAllowsAdoption(history), RepositoryAdoption.matches(dto, request: request) else {
            try run.journal.finish(entry, run.journal.failed(code: SyncExecutionConstants.createConflictErrorCode))
            finish(change, .failed(.createConflict))
            run.repositoryFailure = change.id
            return
        }
        try run.journal.finish(entry, run.journal.reconciled(), effects: [
            RepositoryAdoption.effect(repositoryID: run.repositoryID, dto: dto, fallbackName: ref.name),
        ])
        run.ref = dto.repoRef ?? ref
        if request.spec?.cloneAfter == true {
            warnings.append(.cloneRequested(repositoryID: run.repositoryID))
        }
        finish(change, .succeeded(.notApplicable))
    }

    var retentionStart: Date {
        clock.now.addingTimeInterval(-Timeouts.syncJournalRetention.timeInterval)
    }

    // MARK: - freshRepo window (§7.3 step 1)

    /// Runs `body`, retrying "not found" while the repository created in this run is fresh.
    func fresh<T>(_ run: RepoRun, _ body: () async throws(GHError) -> T) async throws(GHError) -> T {
        var firstMiss: Duration?
        while true {
            do {
                return try await body()
            } catch .notFound {
                guard let start = run.freshRepoStart, clock.uptime - start < Timeouts.freshRepoWindow else {
                    throw .notFound
                }
                let missStart = firstMiss ?? clock.uptime
                firstMiss = missStart
                guard clock.uptime - missStart < Timeouts.freshRepoRetryWindow else { throw .notFound }
                try await sleep(for: Timeouts.freshRepoRetryInterval)
            }
        }
    }

    /// True while the repository created in this run is inside the freshRepo window.
    func isFresh(_ run: RepoRun) -> Bool {
        guard let start = run.freshRepoStart else { return false }
        return clock.uptime - start < Timeouts.freshRepoWindow
    }

    /// Runs `body` and captures its gh outcome (keeps `do` blocks free of SyncError throws).
    func attempt<T>(_ body: () async throws(GHError) -> T) async -> Result<T, GHError> {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }

    func sleep(for duration: Duration) async throws(GHError) {
        do {
            try await clock.sleep(for: duration)
        } catch {
            throw .cancelled
        }
    }

    // MARK: - Bookkeeping

    /// The stop reason, recording a requested cancel first.
    func checkStop() -> SyncStopReason? {
        if stopReason == nil, cancelRequested.withLock({ $0 }) || Task.isCancelled {
            stopReason = .cancelled
        }
        return stopReason
    }

    func stop(_ reason: SyncStopReason) {
        if stopReason == nil { stopReason = reason }
    }

    func started(_ change: ConfigChangeModel) {
        progressContinuation.yield(.changeStarted(changeID: change.id))
    }

    func reportVerifying(_ scope: RemoteScopeKeyModel) {
        progressContinuation.yield(.verifying(scope))
    }

    /// Records the final outcome of `change` (the first one wins) and reports progress.
    func finish(_ change: ConfigChangeModel, _ outcome: SyncChangeOutcomeModel) {
        guard outcomes[change.id] == nil else { return }
        outcomes[change.id] = outcome
        guard plannedChangeIDs.contains(change.id) else { return }
        completedCount += 1
        progressContinuation.yield(.changeFinished(
            SyncChangeResultModel(change: change, outcome: outcome),
            completed: completedCount,
            total: totalCount
        ))
    }

    /// Records a gh failure, stopping the run when the error means nothing else can succeed.
    func fail(_ change: ConfigChangeModel, _ reason: SyncFailureReason) {
        if case .github(let error) = reason, let stop = SyncStopReason.from(error) {
            self.stop(stop)
        }
        finish(change, .failed(reason))
    }

    func skipRemaining(_ changes: [ConfigChangeModel], reason: SyncSkipReason) {
        for change in changes { finish(change, .skipped(reason)) }
    }

    func hasOutcome(_ change: ConfigChangeModel) -> Bool {
        outcomes[change.id] != nil
    }

    func warn(_ warning: SyncWarningModel) {
        warnings.append(warning)
    }
}

/// The sync engine's logger (§4.5): counts, codes and command templates only, never names or
/// values.
enum SyncLog {
    static let sync = Logger(subsystem: GHConstants.logSubsystem, category: "sync")
}

extension GHError {
    /// Failures after which a write may still have reached GitHub, so a read decides.
    var mayHaveApplied: Bool {
        switch self {
        case .indeterminate, .serverError, .network, .timeout, .unexpected, .malformedOutput: true
        default: false
        }
    }
}
