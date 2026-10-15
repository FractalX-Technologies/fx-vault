import Foundation
import GitHubKit
import os
import SyncEngine
import VaultCore
import VaultCrypto
import VaultStore

/// Drift detection and review (§7.7, D13, D28; M5): what changed on GitHub since FX Vault last
/// synced or checked, with both resolutions of each finding.
///
/// **Detection** (``detectOnOpen(_:)``, ``refresh(_:)``) is a full native re-list (B3, B5,
/// B6–B9 through `RemoteConfigReader`, every page, no ETags). On that re-list it first runs the
/// pending-verification pass (§7.3 step 6) and records its outcome, then runs SyncEngine's pure
/// `DriftDetector`. Names our own sync deleted in the last `Timeouts.recentDeletionSuppression`
/// (per the journal) are not reported as "remote added". Variable values are reduced to
/// row-bound fingerprints inside the keyring scope and wiped right after; nothing about values
/// is kept between calls. Opening a repository checks at most once per `Timeouts.driftDebounce`.
///
/// **Resolution** (``resolve(_:option:)``) re-reads the finding's scope from GitHub, checks that
/// GitHub still has what the finding saw (else `.stale`), and applies the effects in one
/// transaction. "Accept GitHub" for a secret ends with an "Enter new value" prompt: call
/// ``enterNewValue(_:value:pushOnNextSync:)`` (fill mode, §7.1).
public actor DriftRepository {
    private struct CachedReport {
        let report: DriftReportModel
        let checkedAtUptime: Duration
    }

    private let session: VaultSession
    private let schedulers: any GHSchedulerProviding
    private let clock: any VaultClock
    private let config: ConfigRepository
    private var reports: [RepoID: CachedReport] = [:]
    /// Pending-verification misses per row (§7.3 step 6). Kept in memory: the schema has no
    /// column for them, so a relaunch starts counting again.
    private var failedChecks: [RepoID: [ConfigItemID: Int]] = [:]

    private static let log = Logger(subsystem: ConfigConstants.logSubsystem, category: "drift")

    public init(
        session: VaultSession,
        schedulers: any GHSchedulerProviding,
        clock: any VaultClock = SystemClock(),
        writePolicy: WriteCollaboratorPolicy = .default
    ) {
        self.session = session
        self.schedulers = schedulers
        self.clock = clock
        config = ConfigRepository(session: session, clock: clock, writePolicy: writePolicy)
    }

    // MARK: - Detection

    /// The check run when a repository is opened: the cached report when the last check is
    /// younger than `Timeouts.driftDebounce`, otherwise a fresh one.
    public func detectOnOpen(_ repositoryID: RepoID) async throws(DriftRepositoryError) -> DriftReportModel {
        if let cached = reports[repositoryID], clock.uptime - cached.checkedAtUptime < Timeouts.driftDebounce {
            return cached.report
        }
        return try await refresh(repositoryID)
    }

    /// **Refresh**: a full re-list and drift check now.
    ///
    /// - Throws: `.repositoryNotFound`, `.vault(.locked)`, `.github` when nothing could be read
    ///   (token, network, rate limit); scope-level read failures are in
    ///   ``DriftReportModel/unreadable`` instead.
    public func refresh(_ repositoryID: RepoID) async throws(DriftRepositoryError) -> DriftReportModel {
        guard !session.isLocked else { throw .vault(.locked) }
        let local = try loadSnapshot(repositoryID)
        guard local.repository.existsOnGitHub else {
            return cache(DriftReportModel(repositoryID: repositoryID, checkedAt: clock.now))
        }
        let scheduler = try await scheduler(for: local.repository)
        let ref = try Self.ref(of: local.repository)
        let listed: RemoteRepoConfigModel
        do {
            listed = try await RemoteConfigReader(scheduler: scheduler, repo: ref).read()
        } catch {
            throw .github(error)
        }
        defer { listed.wipe() }
        let inputs = DriftRemoteInputs(listed)
        let remote = try performDrift {
            try session.withKeys { keys in
                let keys = copy keys
                return RemoteSnapshotModel(
                    local: local,
                    repository: inputs.repository,
                    environments: inputs.environments,
                    fingerprint: { value, rowID in keys.fingerprint(value, rowID: rowID) }
                )
            }
        }

        let pass = WriteVerifier.pendingVerificationPass(
            local: local,
            remote: remote,
            failedChecks: failedChecks[repositoryID] ?? [:]
        )
        if !pass.effects.isEmpty {
            do {
                try VaultSyncPersistence(session: session, clock: clock).commit(SyncCommitModel(effects: pass.effects))
            } catch {
                throw .wrap(error)
            }
        }
        failedChecks[repositoryID] = pass.failedChecks

        var drifts = DriftDetector.detect(local: pass.snapshot, remote: remote, suppression: try suppression(repositoryID))
        if !inputs.environmentsListed {
            drifts.removeAll { if case .environment = $0.subject { true } else { false } }
        }
        let report = DriftReportModel(
            repositoryID: repositoryID,
            checkedAt: clock.now,
            drifts: drifts,
            unreadable: listed.failures,
            verifiedItems: pass.verified,
            expiredItems: pass.expired,
            skippedNames: listed.skipped
        )
        Self.log.info(
            "Drift check: \(drifts.count, privacy: .public) findings, \(listed.failures.count, privacy: .public) unreadable reads"
        )
        return cache(report)
    }

    /// The last report of `repositoryID`, if any (the banner), without checking.
    public func report(for repositoryID: RepoID) -> DriftReportModel? {
        reports[repositoryID]?.report
    }

    /// Forgets every cached report and miss count (for example after a lock).
    public func reset() {
        reports = [:]
        failedChecks = [:]
    }

    // MARK: - Resolution

    /// Applies `option` for `drift` (§7.7 table) after re-reading the finding's scope.
    ///
    /// - Throws: `.resolutionUnavailable` (for example "Keep local" without a value), `.stale`
    ///   when GitHub or the local row changed since the check (refresh and review again),
    ///   `.github`, `.vault(.locked)`.
    @discardableResult
    public func resolve(
        _ drift: DriftModel,
        option: DriftResolutionOption
    ) async throws(DriftRepositoryError) -> DriftResolutionResultModel {
        let resolution = drift.resolution(option)
        if let reason = resolution.unavailableReason { throw .resolutionUnavailable(reason) }
        guard !session.isLocked else { throw .vault(.locked) }
        let repository = try loadSnapshot(drift.repositoryID).repository
        let remote = try await remoteState(for: drift.subject, repository: repository)
        defer { remote.wipe() }
        let database = session.database
        let now = clock.now
        try performDrift {
            try session.write { keys, tx in
                let applier = DriftEffectApplier(
                    rows: SyncRowWriter(database: database, tx: tx, now: now),
                    keys: copy keys,
                    repositoryID: drift.repositoryID,
                    remote: remote
                )
                for effect in resolution.effects {
                    try applier.apply(effect)
                }
            }
        }
        if let cached = reports[drift.repositoryID] {
            var report = cached.report
            report.drifts.removeAll { $0.id == drift.id }
            reports[drift.repositoryID] = CachedReport(report: report, checkedAtUptime: cached.checkedAtUptime)
        }
        Self.log.info("Resolved a \(drift.kind.rawValue, privacy: .public) finding with \(option.rawValue, privacy: .public)")
        return DriftResolutionResultModel(driftID: drift.id, option: option, followUp: resolution.followUp)
    }

    /// "Enter new value" after a secret's "Accept GitHub" (§7.7): fills the value-missing secret.
    /// By default the value is taken as what GitHub has (nothing pending); with
    /// `pushOnNextSync` the next Sync pushes it. The value is normalized (D32).
    @discardableResult
    public func enterNewValue(
        _ itemID: ConfigItemID,
        value: SecretBytes,
        pushOnNextSync: Bool = false
    ) throws(DriftRepositoryError) -> ItemWriteResultModel {
        do {
            return try config.fillValue(itemID, value: value, pushOnNextSync: pushOnNextSync)
        } catch {
            throw .config(error)
        }
    }

    // MARK: - Private

    private func cache(_ report: DriftReportModel) -> DriftReportModel {
        reports[report.repositoryID] = CachedReport(report: report, checkedAtUptime: clock.uptime)
        return report
    }

    private func loadSnapshot(_ repositoryID: RepoID) throws(DriftRepositoryError) -> RepoSnapshotModel {
        let inputs = try performDrift { try ConfigStore(database: session.database).fetchPendingInputs(repositoryID: repositoryID) }
        guard let inputs else { throw .repositoryNotFound }
        return RepoSnapshotMapper.snapshot(inputs)
    }

    private func scheduler(for repository: RepoModel) async throws(DriftRepositoryError) -> GHCommandScheduler {
        do {
            return try await schedulers.scheduler(for: repository.accountLogin)
        } catch {
            throw .github(error)
        }
    }

    private static func ref(of repository: RepoModel) throws(DriftRepositoryError) -> GHRepoRef {
        do {
            return try GHRepoRef(owner: repository.ownerLogin, name: repository.name)
        } catch {
            throw .github(error)
        }
    }

    /// Names our own sync deleted recently (§7.7, D28).
    private func suppression(_ repositoryID: RepoID) throws(DriftRepositoryError) -> DriftSuppressionModel {
        let since = clock.now.addingTimeInterval(-Timeouts.recentDeletionSuppression.timeInterval)
        let commands = Set(SyncJournalCommand.deletions.map(\.rawValue))
        let rows = try performDrift {
            try SyncJournalStore(database: session.database).fetchSucceeded(repositoryID: repositoryID, commands: commands, since: since)
        }
        return DriftSuppressionModel(journalTargetKeys: rows.map(\.targetKey))
    }

    /// GitHub's current state of a finding's subject: the item's scope (B6/B8 or B7/B9), or
    /// the whole environment list with the subject environment's patterns and items.
    private func remoteState(
        for subject: DriftSubjectModel,
        repository: RepoModel
    ) async throws(DriftRepositoryError) -> DriftRemoteStateModel {
        let scheduler = try await scheduler(for: repository)
        let ref = try Self.ref(of: repository)
        switch subject {
        case .item(let item):
            if item.key.scope.environmentKey != nil, item.environmentName == nil { throw .stale }
            do {
                switch item.kind {
                case .secret:
                    let secrets = try await scheduler.listSecrets(ref, environment: item.environmentName)
                    let listed = secrets.first { GitHubNameValidator.foldKey($0.name) == item.key.nameKey }
                    return DriftRemoteStateModel(item: listed.map { DriftListedItemModel(name: $0.name, updatedAt: $0.updatedAt, value: nil) })
                case .variable:
                    let variables = try await scheduler.listVariables(ref, environment: item.environmentName)
                    var match: DriftListedItemModel?
                    for variable in variables {
                        if match == nil, GitHubNameValidator.foldKey(variable.name) == item.key.nameKey {
                            match = DriftListedItemModel(name: variable.name, updatedAt: variable.updatedAt, value: variable.value)
                        } else {
                            variable.wipe()
                        }
                    }
                    return DriftRemoteStateModel(item: match)
                }
            } catch {
                throw .github(error)
            }
        case .environment(let environment):
            let listed: RemoteRepoConfigModel
            do {
                listed = try await RemoteConfigReader(scheduler: scheduler, repo: ref).read()
            } catch {
                throw .github(error)
            }
            if listed.failures.contains(where: { $0.target == .environments }) {
                listed.wipe()
                throw .stale
            }
            var match: RemoteEnvironmentConfigModel?
            for candidate in listed.environments {
                if match == nil, RemoteScopeKeyModel.environment(named: candidate.name) == environment.key {
                    match = candidate
                } else {
                    candidate.variables.forEach { $0.wipe() }
                }
            }
            listed.variables.forEach { $0.wipe() }
            return DriftRemoteStateModel(environment: match)
        }
    }
}
