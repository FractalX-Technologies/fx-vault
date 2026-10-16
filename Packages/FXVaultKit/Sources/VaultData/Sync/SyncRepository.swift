import EnvTools
import Foundation
import GitHubKit
import os
import SyncEngine
import VaultCore
import VaultStore

/// Sync for the app (§7.2–§7.5, D12, D27, D28; M3, M4): the pending summary, launch
/// reconciliation, preflight, the deletion preview, the run itself and the last-run report.
///
/// It wires SyncEngine to the vault: ``VaultSyncPersistence`` (journal and row bookkeeping in one
/// transaction per outcome) and ``VaultSyncValues`` (values decrypted inside `VaultSession`),
/// with one `GHCommandScheduler` per account from ``GHSchedulerProviding``.
///
/// - **Throttle seeding (D12).** The schedulers come from `GitHubEnvironmentRepository`, which
///   seeds each one from the journal when it creates it. This repository never seeds again
///   (seeding appends, so a second seed would double count).
/// - **Launch.** ``prepareAfterUnlock()`` prunes the journal (24 h, the latest run kept) and
///   reconciles leftover `in_flight`/`indeterminate` rows by re-listing. ``preflight(repositoryIDs:scopeStatus:)``
///   runs it automatically once per unlock, so a new Sync never starts before reconciliation.
/// - **One run at a time.** ``startRun(_:includeDeletions:cloneFolder:spaceReason:)`` refuses
///   while another run is in progress.
/// - **Shared spaces (v0.6.0, S5).** With a ``SyncSpaceCoordinating`` (``SpaceRepository``),
///   preflight gates every shared scope on its GitHub marker, the run claims and publishes it,
///   and ``prepareAfterUnlock()`` finishes claims a crash or a failed marker write left open.
public actor SyncRepository {
    private let session: VaultSession
    private let schedulers: any GHSchedulerProviding
    private let cloner: (any RepoCloning)?
    private let clock: any VaultClock
    private let writePolicy: WriteCollaboratorPolicy
    private let spaces: (any SyncSpaceCoordinating)?
    private let persistence: VaultSyncPersistence
    private let values: VaultSyncValues
    /// The keyring generation launch reconciliation last ran under (nil: not since launch).
    private var reconciledGeneration: UInt64?
    private var activeRun: SyncRunHandle?

    private static let log = Logger(subsystem: ConfigConstants.logSubsystem, category: "sync")

    /// - Parameters:
    ///   - schedulers: `GitHubEnvironmentRepository` in the app.
    ///   - cloner: clones repositories created with "clone after" (``RepoCreationRepository``).
    ///   - writePolicy: what a WRITE collaborator may change (§2 Permissions, Q6).
    ///   - spaces: shared spaces (``SpaceRepository``); nil syncs every scope as unshared.
    public init(
        session: VaultSession,
        schedulers: any GHSchedulerProviding,
        cloner: (any RepoCloning)? = nil,
        clock: any VaultClock = SystemClock(),
        writePolicy: WriteCollaboratorPolicy = .default,
        spaces: (any SyncSpaceCoordinating)? = nil
    ) {
        self.session = session
        self.schedulers = schedulers
        self.cloner = cloner
        self.clock = clock
        self.writePolicy = writePolicy
        self.spaces = spaces
        persistence = VaultSyncPersistence(session: session, clock: clock)
        values = VaultSyncValues(session: session)
    }

    // MARK: - Pending changes (§7.2)

    /// The pending summary of every repository with a pending or blocked change (names and
    /// counts only). Needs no keys.
    public nonisolated func pendingSummary() throws(SyncRepositoryError) -> ChangeSummaryModel {
        let all = try performSync { try ConfigStore(database: session.database).fetchAllPendingInputs() }
        return Self.summary(all)
    }

    /// ``pendingSummary()`` now and after every change to the vault rows.
    public nonisolated func observePendingSummary() -> AsyncThrowingStream<ChangeSummaryModel, any Error> {
        ObservationMapper.map(ConfigStore(database: session.database).observeAllPendingInputs()) { all in
            Self.summary(all)
        }
    }

    static func summary(_ all: [RepoPendingInputsModel]) -> ChangeSummaryModel {
        let changeSets = all
            .map { ChangeSetBuilder.build(RepoSnapshotMapper.snapshot($0)) }
            .filter { !$0.allChanges.isEmpty }
        return ChangeSummaryBuilder.summarize(changeSets)
    }

    // MARK: - Launch (§7.3 indeterminate outcomes, D28)

    /// Prunes the journal and reconciles rows a crash or an unconfirmed timeout left
    /// unresolved. Call it after every unlock; ``preflight(repositoryIDs:scopeStatus:)`` calls it
    /// itself when it has not run since the last unlock.
    ///
    /// - Throws: `.vault(.locked)`, `.sync(.persistenceFailed)`.
    @discardableResult
    public func prepareAfterUnlock() async throws(SyncRepositoryError) -> SyncReconciliationModel {
        let generation = session.generation
        let now = clock.now
        let pruned = try performSync { try SyncJournalStore(database: session.database).pruneExpired(now: now) }
        let unresolved: [SyncJournalEntryModel]
        do {
            unresolved = try persistence.journalEntries(states: SyncJournalOutcomeState.unresolved)
        } catch {
            throw .wrap(error)
        }
        var result = SyncReconciliationModel()
        if !unresolved.isEmpty {
            let snapshots = try loadSnapshots(Set(unresolved.compactMap(\.repositoryID)))
            let registry = await registry(for: Set(snapshots.map(\.repository.accountLogin) + unresolved.map(\.accountLogin)))
            do {
                result = try await SyncReconciler(
                    schedulers: registry,
                    persistence: persistence,
                    values: values,
                    clock: clock
                ).reconcile(snapshots)
            } catch {
                throw .wrap(error)
            }
        }
        try await reconcileSpaceClaims()
        reconciledGeneration = generation
        Self.log.info(
            """
            Launch reconciliation: pruned \(pruned, privacy: .public) rows, \
            \(result.reconciled.count, privacy: .public) reconciled, \(result.failed.count, privacy: .public) failed, \
            \(result.conflicts.count, privacy: .public) conflicts, \(result.unchecked.count, privacy: .public) unchecked
            """
        )
        return result
    }

    /// Finishes shared space claims a crash or a failed marker write left open (after the journal
    /// reconciliation, so the rows match GitHub).
    private func reconcileSpaceClaims() async throws(SyncRepositoryError) {
        guard let spaces else { return }
        let all = try performSync { try SpaceStore(database: session.database).fetchSpaces() }
        let claimed = Set(all.filter { $0.claimedVersion != nil }.map(\.repositoryID))
        guard !claimed.isEmpty else { return }
        let snapshots = try loadSnapshots(claimed)
        let registry = await registry(for: Set(snapshots.map(\.repository.accountLogin)))
        await SpaceClaimReconciler(schedulers: registry, spaces: spaces).reconcile(snapshots)
    }

    // MARK: - Preflight (§7.3)

    /// Runs the preflight for `repositoryIDs` (nil: every repository with a pending or blocked
    /// change): capability, names, values, optimistic concurrency (D27), scope capacity, the
    /// hourly write budget, and the credential check of variables (§5.13).
    ///
    /// - Parameters:
    ///   - scopeStatus: each account's token scope status (A3), keyed by login.
    ///   - spaceTakeovers: shared spaces whose stale claim the user confirmed taking over (Q3).
    /// - Throws: `.alreadyRunning`, `.vault(.locked)`, `.sync(.persistenceFailed)`. gh failures
    ///   never throw: they block the affected changes.
    public func preflight(
        repositoryIDs: [RepoID]? = nil,
        scopeStatus: [String: ScopeStatus] = [:],
        spaceTakeovers: Set<SpaceID> = []
    ) async throws(SyncRepositoryError) -> SyncReviewModel {
        try requireNoActiveRun()
        if reconciledGeneration != session.generation {
            try await prepareAfterUnlock()
        }
        let snapshots = try loadSnapshots(repositoryIDs.map(Set.init))
            .filter { !ChangeSetBuilder.build($0).allChanges.isEmpty }
        let registry = await registry(for: Set(snapshots.map(\.repository.accountLogin)))
        let preflight: SyncPreflightModel
        do {
            preflight = try await SyncPreflight(
                schedulers: registry,
                persistence: persistence,
                values: values,
                clock: clock,
                writePolicy: writePolicy,
                spaces: spaces
            ).run(snapshots, scopeStatus: scopeStatus, spaceTakeovers: spaceTakeovers)
        } catch {
            throw .wrap(error)
        }
        return SyncReviewModel(preflight: preflight, credentialWarnings: try credentialWarnings(preflight))
    }

    /// The §7.5 deletion data: every environment being deleted is fetched live (B4, B5, B7, B9)
    /// and merged with the local names. Never throws: a failed fetch is "contents unknown".
    public func deletionPreview(for review: SyncReviewModel) async -> [RepoDeletionPreviewModel] {
        let logins = Set(review.preflight.repositories.map(\.snapshot.repository.accountLogin))
        return await DeletionPreviewLoader(schedulers: registry(for: logins)).load(review.preflight)
    }

    // MARK: - Run (§7.3, §7.4)

    /// Plans and starts the run. Deletions are left out (and reported as not confirmed) unless
    /// the user confirmed them (§7.5). Repositories created with "clone after" are cloned into
    /// `cloneFolder` once the run finished. `spaceReason` ("What changed?") goes into every shared
    /// space version the run publishes.
    ///
    /// - Throws: `.alreadyRunning`, `.vault(.locked)`.
    public func startRun(
        _ review: SyncReviewModel,
        includeDeletions: Bool,
        cloneFolder: URL? = nil,
        spaceReason: String? = nil
    ) async throws(SyncRepositoryError) -> SyncRunHandle {
        try requireNoActiveRun()
        do {
            try values.ensureUnlocked()
        } catch {
            throw .wrap(error)
        }
        let plan = SyncPlanner.plan(review.preflight, includeDeletions: includeDeletions, spaceReason: spaceReason)
        let registry = await registry(for: Set(plan.repositories.map(\.snapshot.repository.accountLogin)))
        let executor = SyncExecutor(schedulers: registry, persistence: persistence, values: values, clock: clock, spaces: spaces)
        let handle = SyncRunHandle(executor: executor, plan: plan, cloner: cloner, cloneFolder: cloneFolder)
        activeRun = handle
        Self.log.info("Sync run started with \(plan.changeCount, privacy: .public) changes")
        return handle
    }

    /// The run in progress, if any.
    public var currentRun: SyncRunHandle? {
        guard let activeRun, !activeRun.isFinished else { return nil }
        return activeRun
    }

    // MARK: - Last run report (D28)

    /// The latest run in the journal, or nil when the journal is empty.
    public nonisolated func lastRunReport() throws(SyncRepositoryError) -> SyncRunReportModel? {
        let records = try performSync { try SyncJournalStore(database: session.database).fetchLatestRun() }
        return Self.report(records)
    }

    /// ``lastRunReport()`` now and after every journal change.
    public nonisolated func observeLastRunReport() -> AsyncThrowingStream<SyncRunReportModel?, any Error> {
        ObservationMapper.map(SyncJournalStore(database: session.database).observeLatestRun()) { records in
            Self.report(records)
        }
    }

    static func report(_ records: [SyncJournalRecord]) -> SyncRunReportModel? {
        guard let runID = records.first?.runID else { return nil }
        return SyncRunReportModel(runID: runID, entries: records.compactMap(SyncJournalMapper.model))
    }

    // MARK: - Private

    private func requireNoActiveRun() throws(SyncRepositoryError) {
        if let activeRun, !activeRun.isFinished { throw .alreadyRunning }
    }

    /// Snapshots of `ids` (nil: every repository), in sidebar order.
    private func loadSnapshots(_ ids: Set<RepoID>?) throws(SyncRepositoryError) -> [RepoSnapshotModel] {
        let all = try performSync { try ConfigStore(database: session.database).fetchAllPendingInputs() }
        return all
            .filter { ids?.contains($0.repository.id) ?? true }
            .map(RepoSnapshotMapper.snapshot)
    }

    /// One scheduler per account. An account without gh access is left out: preflight then
    /// blocks its changes and reconciliation leaves its rows unchecked.
    private func registry(for logins: Set<String>) async -> SyncSchedulerRegistry {
        var seen: Set<String> = []
        var found: [GHCommandScheduler] = []
        for login in logins.sorted() where seen.insert(OwnerLoginValidator.foldKey(login)).inserted {
            do {
                found.append(try await schedulers.scheduler(for: login))
            } catch {
                Self.log.error("No gh scheduler for an account: \(error.logCode, privacy: .public)")
            }
        }
        return SyncSchedulerRegistry(found)
    }

    /// §5.13: variables about to be pushed whose name or value looks like a credential.
    private func credentialWarnings(_ preflight: SyncPreflightModel) throws(SyncRepositoryError) -> [SyncCredentialWarningModel] {
        var warnings: [SyncCredentialWarningModel] = []
        for repository in preflight.repositories {
            for change in repository.executable {
                guard case .setItem(let set) = change.operation, set.kind == .variable else { continue }
                let value: SyncItemValueModel?
                do {
                    value = try values.value(of: set.itemID)
                } catch {
                    throw .wrap(error)
                }
                defer { value?.wipe() }
                let assessment = CredentialClassifier.assess(key: set.name, value: value?.value)
                guard assessment.isLikelyCredential else { continue }
                warnings.append(SyncCredentialWarningModel(
                    changeID: change.id,
                    repositoryID: repository.id,
                    itemID: set.itemID,
                    name: set.name,
                    environmentName: set.environmentName,
                    reasons: assessment.reasons
                ))
            }
        }
        return warnings
    }
}
