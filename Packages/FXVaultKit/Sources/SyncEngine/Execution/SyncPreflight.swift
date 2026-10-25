import Foundation
import GitHubKit
import VaultCore

/// Sync preflight (tasks/todo.md §7.3, D27): everything checked before the user confirms.
///
/// Per repository:
/// 1. The vault is unlocked (``SyncValueProviding/ensureUnlocked()``) and the account has a
///    scheduler; a `.missing` token scope status blocks the repository (`.unknown` passes).
/// 2. A repository to create is looked up with B2, journaled (the reconciliation fact, §7.3).
///    If it already exists it is adopted when the journal proves it is ours (an earlier "free"
///    lookup followed by a create attempt) with the expected owner and visibility; otherwise
///    the create is blocked as `remoteChanged`.
/// 3. Changes are derived (``ChangeSetBuilder``), then checked: capability
///    (`RepoCapabilityModel`; environments need admin), names (validators, D29), values
///    (non-empty and ≤ `Limits.maxValueBytes` after D32 normalization).
/// 4. Optimistic concurrency (D27): every touched scope is re-listed (B3, B6–B9), the
///    pending-verification pass runs on that re-list (without counting misses), and each
///    change's base is checked with ``RemoteBaseChecker``. Moved bases are blocked as
///    `.remoteChanged` through ``ChangeSetModel/blocking(_:reason:)``. A policy change on an
///    existing environment that B3 lists with other protection rules is blocked as
///    ``SyncBlockReason/protectionRulesPresent`` (C2 omits them; Q6 unverified).
/// 5. Scope capacity (`ScopeCapacityValidator`) against the listed counts.
/// 6. The hourly write budget of each account (seed the scheduler once at launch with
///    ``SyncThrottleSeeder``).
///
/// `pre_write_updated_at` is captured by the executor's per-scope re-list right before each
/// scope's writes (§7.3 step 4), which supersedes a preflight capture.
public struct SyncPreflight: Sendable {
    private let schedulers: SyncSchedulerRegistry
    private let persistence: any SyncPersisting
    private let values: any SyncValueProviding
    private let clock: any VaultClock
    private let writePolicy: WriteCollaboratorPolicy

    public init(
        schedulers: SyncSchedulerRegistry,
        persistence: any SyncPersisting,
        values: any SyncValueProviding,
        clock: any VaultClock,
        writePolicy: WriteCollaboratorPolicy = .default
    ) {
        self.schedulers = schedulers
        self.persistence = persistence
        self.values = values
        self.clock = clock
        self.writePolicy = writePolicy
    }

    /// Runs the preflight for `snapshots`.
    ///
    /// - Parameters:
    ///   - runID: the run the lookups are journaled under (reused by the executor).
    ///   - scopeStatus: each account's token scope status (A3), keyed by login; absent = `.ok`.
    /// - Throws: ``SyncError/locked`` or ``SyncError/persistenceFailed``. gh failures never
    ///   throw: they block the affected changes with ``SyncBlockReason/listingFailed(_:)``.
    public func run(
        _ snapshots: [RepoSnapshotModel],
        runID: SyncRunID = SyncRunID(),
        scopeStatus: [String: ScopeStatus] = [:]
    ) async throws(SyncError) -> SyncPreflightModel {
        try values.ensureUnlocked()
        var repositories: [RepoPreflightModel] = []
        var budgets: [String: WriteBudgetModel] = [:]
        var cost = 0
        for snapshot in snapshots {
            let login = snapshot.repository.accountLogin
            let status = scopeStatus.first { OwnerLoginValidator.foldKey($0.key) == OwnerLoginValidator.foldKey(login) }?.value
            let repository = try await preflight(snapshot, runID: runID, scopeStatus: status ?? .ok)
            cost += repository.executable.map { WriteCostEstimator.cost(of: $0, snapshot: repository.snapshot) }.reduce(0, +)
            repositories.append(repository)
            if let scheduler = schedulers.scheduler(for: login), budgets[login] == nil {
                budgets[login] = WriteBudgetModel(used: await scheduler.writesInLastHour)
            }
        }
        return SyncPreflightModel(runID: runID, repositories: repositories, writeBudgets: budgets, estimatedWriteCost: cost)
    }

    // MARK: - One repository

    private func preflight(
        _ input: RepoSnapshotModel,
        runID: SyncRunID,
        scopeStatus: ScopeStatus
    ) async throws(SyncError) -> RepoPreflightModel {
        var snapshot = input
        guard let scheduler = schedulers.scheduler(for: snapshot.repository.accountLogin) else {
            return blockingEverything(snapshot, reason: .listingFailed(.notAuthenticated))
        }
        let journal = SyncJournalWriter(
            persistence: persistence,
            clock: clock,
            runID: runID,
            accountLogin: snapshot.repository.accountLogin,
            repositoryID: snapshot.repository.id
        )
        var reasons: [String: SyncBlockReason] = [:]
        var remoteChanged: Set<String> = []

        if !snapshot.repository.existsOnGitHub {
            switch try await lookUpRepositoryToCreate(&snapshot, scheduler: scheduler, journal: journal) {
            case .free, .adopted:
                break
            case .taken(let createID):
                remoteChanged.insert(createID)
            case .failed(let error):
                return blockingEverything(snapshot, reason: .listingFailed(error))
            }
        }

        var changeSet = ChangeSetBuilder.build(snapshot)
        if case .missing(let scopes) = scopeStatus {
            for change in changeSet.changes { reasons[change.id] = .missingScopes(scopes) }
        }
        checkCapability(changeSet.changes, repository: snapshot.repository, into: &reasons)
        checkNames(changeSet.changes, into: &reasons)
        try checkValues(changeSet.changes, into: &reasons)

        if snapshot.repository.existsOnGitHub {
            let remote = await listTouchedScopes(changeSet.changes, snapshot: snapshot, scheduler: scheduler)
            let state = try buildRemoteState(remote, snapshot: snapshot)
            let pass = WriteVerifier.pendingVerificationPass(
                local: snapshot,
                remote: state.snapshot,
                countsMisses: false
            )
            if !pass.effects.isEmpty {
                try persistence.commit(SyncCommitModel(effects: pass.effects))
                snapshot = pass.snapshot
            }
            let owned = try ownedEnvironmentTargets(snapshot.repository.id)
            checkRemoteBases(
                changeSet.changes,
                snapshot: snapshot,
                remote: remote,
                listings: state.listings,
                ownedTargets: owned,
                remoteChanged: &remoteChanged,
                reasons: &reasons
            )
            checkCapacity(changeSet.changes, snapshot: snapshot, listings: state.listings, into: &reasons)
        }

        changeSet = changeSet.blocking(remoteChanged.intersection(Set(changeSet.changes.map(\.id))), reason: .remoteChanged)
        let cascade = BlockCascade.apply(reasons, to: changeSet.changes)
        let blocked = changeSet.blocked.map { SyncBlockedChangeModel(change: $0.change, reason: .change($0.reason)) }
            + cascade.blocked
        return RepoPreflightModel(
            snapshot: snapshot,
            changeSet: changeSet,
            executable: cascade.executable,
            blocked: blocked.sorted { $0.change < $1.change },
            repositoryVariableBytes: try repositoryVariableBytes(snapshot)
        )
    }

    /// Size of every live repository-level variable value, D32-normalized (§7.3 256 KB warning).
    private func repositoryVariableBytes(_ snapshot: RepoSnapshotModel) throws(SyncError) -> Int {
        var total = 0
        for row in snapshot.items(in: .repository) where row.kind == .variable && !row.isDeleted {
            guard let value = try values.value(of: row.id) else { continue }
            total += value.value.withUnsafeBytes { $0.count - ValueNormalizer.trailingNewlineCount(in: $0) }
            value.wipe()
        }
        return total
    }

    private func blockingEverything(_ snapshot: RepoSnapshotModel, reason: SyncBlockReason) -> RepoPreflightModel {
        let changeSet = ChangeSetBuilder.build(snapshot)
        let blocked = changeSet.blocked.map { SyncBlockedChangeModel(change: $0.change, reason: .change($0.reason)) }
            + changeSet.changes.map { SyncBlockedChangeModel(change: $0, reason: reason) }
        return RepoPreflightModel(
            snapshot: snapshot,
            changeSet: changeSet,
            executable: [],
            blocked: blocked.sorted { $0.change < $1.change }
        )
    }

    // MARK: - Repository creation (§7.3 step 1, reconciliation)

    private enum CreateLookup {
        case free
        case adopted
        /// The name exists and is not ours; the create change's id.
        case taken(String)
        case failed(GHError)
    }

    private func lookUpRepositoryToCreate(
        _ snapshot: inout RepoSnapshotModel,
        scheduler: GHCommandScheduler,
        journal: SyncJournalWriter
    ) async throws(SyncError) -> CreateLookup {
        let repository = snapshot.repository
        guard let create = ChangeSetBuilder.build(snapshot).changes.first(where: { $0.kind == .createRepository }),
              case .createRepository(let request) = create.operation
        else { return .free }
        let ref: GHRepoRef
        do {
            ref = try GHRepoRef(owner: repository.ownerLogin, name: repository.name)
        } catch {
            return .failed(error)
        }
        let entryID = try journal.begin(create, command: .repoView)
        let dto: GHRepoDTO
        do {
            dto = try await scheduler.viewRepository(ref)
        } catch {
            try journal.finish(entryID, journal.failed(error))
            return error == .notFound ? .free : .failed(error)
        }
        try journal.finish(entryID, journal.succeeded())
        let history = try persistence.journalEntries(repositoryID: repository.id, since: retentionStart)
        guard RepositoryAdoption.journalAllowsAdoption(history), RepositoryAdoption.matches(dto, request: request) else {
            return .taken(create.id)
        }
        let unresolved = history.filter { $0.command == .repoCreate && SyncJournalOutcomeState.unresolved.contains($0.state) }
        try persistence.commit(SyncCommitModel(
            journal: unresolved.compactMap { entry in entry.id.map { SyncJournalUpdateModel(id: $0, outcome: journal.reconciled()) } },
            effects: [RepositoryAdoption.effect(repositoryID: repository.id, dto: dto, fallbackName: repository.name)]
        ))
        RepositoryAdoption.apply(dto, to: &snapshot)
        return .adopted
    }

    private var retentionStart: Date {
        clock.now.addingTimeInterval(-Timeouts.syncJournalRetention.timeInterval)
    }

    /// Environment fold keys our own earlier PUTs created (a crash or failed rename verification
    /// can leave them on GitHub before the vault recorded them).
    private func ownedEnvironmentTargets(_ repositoryID: RepoID) throws(SyncError) -> Set<String> {
        Set(try persistence.journalEntries(repositoryID: repositoryID, since: retentionStart)
            .filter { $0.command == .environmentPut && $0.state != .failed && $0.state != .skipped }
            .map(\.targetKey))
    }

    // MARK: - Local checks

    private func checkCapability(
        _ changes: [ConfigChangeModel],
        repository: RepoModel,
        into reasons: inout [String: SyncBlockReason]
    ) {
        guard repository.existsOnGitHub else { return }
        let capability = repository.capability(writePolicy: writePolicy)
        for change in changes where reasons[change.id] == nil {
            let level: ConfigScopeLevel = switch change.operation {
            case .createRepository: .repository
            case .upsertEnvironment, .renameEnvironment, .reconcileBranchPatterns, .deleteEnvironment: .environment
            case .setItem, .deleteItem: change.scope.level
            }
            if let reason = capability.readOnlyReason(for: level) {
                reasons[change.id] = .readOnly(reason)
            }
        }
    }

    private func checkNames(_ changes: [ConfigChangeModel], into reasons: inout [String: SyncBlockReason]) {
        for change in changes where reasons[change.id] == nil {
            do {
                switch change.operation {
                case .createRepository:
                    break
                case .upsertEnvironment(let upsert):
                    _ = try EnvironmentNameValidator.validate(upsert.name)
                case .renameEnvironment(let rename):
                    _ = try EnvironmentNameValidator.validate(rename.fromName)
                    _ = try EnvironmentNameValidator.validate(rename.toName)
                case .reconcileBranchPatterns(let patterns):
                    _ = try EnvironmentNameValidator.validate(patterns.environmentName)
                    for pattern in patterns.desired { try BranchPatternValidator.validate(pattern.pattern) }
                case .deleteEnvironment(let delete):
                    _ = try EnvironmentNameValidator.validate(delete.name)
                case .setItem(let set):
                    _ = try GitHubNameValidator.validate(set.name)
                    if let environment = set.environmentName { _ = try EnvironmentNameValidator.validate(environment) }
                case .deleteItem(let delete):
                    _ = try GitHubNameValidator.validate(delete.name)
                    if let environment = delete.environmentName { _ = try EnvironmentNameValidator.validate(environment) }
                }
            } catch {
                reasons[change.id] = .invalidName(error)
            }
        }
    }

    /// Every value to push decrypts, and is non-empty and within the limit after D32.
    private func checkValues(_ changes: [ConfigChangeModel], into reasons: inout [String: SyncBlockReason]) throws(SyncError) {
        for change in changes where reasons[change.id] == nil {
            guard case .setItem(let set) = change.operation else { continue }
            guard let value = try values.value(of: set.itemID) else {
                reasons[change.id] = .change(.valueMissing)
                continue
            }
            defer { value.wipe() }
            do {
                try ValueNormalizer.normalize(value.value).value.wipe()
            } catch {
                reasons[change.id] = .invalidValue(error)
            }
        }
    }

    // MARK: - Remote state (D27)

    /// The fresh listings preflight took.
    private struct RemoteListings {
        /// B3 by fold key; nil when B3 was not needed. A failure is in ``environmentsError``.
        var environments: [RemoteScopeKeyModel: GHEnvironmentDTO]?
        var environmentsError: GHError?
        /// B6 + B8 (repository) and B7 + B9 (environments) by remote scope.
        var scopes: [RemoteScopeKeyModel: (secrets: [GHSecretDTO], variables: [GHVariableListingModel])] = [:]
        var scopeErrors: [RemoteScopeKeyModel: GHError] = [:]
    }

    private func listTouchedScopes(
        _ changes: [ConfigChangeModel],
        snapshot: RepoSnapshotModel,
        scheduler: GHCommandScheduler
    ) async -> RemoteListings {
        var listings = RemoteListings()
        let ref: GHRepoRef
        do {
            ref = try GHRepoRef(owner: snapshot.repository.ownerLogin, name: snapshot.repository.name)
        } catch {
            listings.environmentsError = error
            listings.scopeErrors[.repository] = error
            return listings
        }
        var scopes: Set<RemoteScopeKeyModel> = []
        var needsEnvironments = false
        for change in changes {
            switch change.operation {
            case .createRepository:
                break
            case .upsertEnvironment, .reconcileBranchPatterns, .deleteEnvironment:
                needsEnvironments = true
            case .renameEnvironment(let rename):
                needsEnvironments = true
                scopes.insert(.environment(named: rename.fromName))
            case .setItem, .deleteItem:
                scopes.insert(change.scope)
                needsEnvironments = needsEnvironments || change.scope.environmentKey != nil
            }
        }
        if needsEnvironments {
            do {
                let environments = try await scheduler.listEnvironments(ref)
                listings.environments = Dictionary(
                    environments.filter(\.hasValidName).map { (RemoteScopeKeyModel.environment(named: $0.name), $0) },
                    uniquingKeysWith: { first, _ in first }
                )
            } catch {
                listings.environmentsError = error
            }
        }
        for scope in scopes.sorted() {
            let environmentName: String?
            if scope.environmentKey == nil {
                environmentName = nil
            } else if let found = listings.environments?[scope] {
                environmentName = found.name
            } else {
                continue
            }
            do {
                let secrets = try await scheduler.listSecrets(ref, environment: environmentName)
                let variables = try await scheduler.listVariables(ref, environment: environmentName)
                listings.scopes[scope] = (secrets, variables)
            } catch {
                listings.scopeErrors[scope] = error
            }
        }
        return listings
    }

    /// The fingerprinted listings and the remote snapshot the pending-verification pass needs.
    private func buildRemoteState(
        _ remote: RemoteListings,
        snapshot: RepoSnapshotModel
    ) throws(SyncError) -> (snapshot: RemoteSnapshotModel, listings: [RemoteScopeKeyModel: RemoteScopeListingModel]) {
        var listings: [RemoteScopeKeyModel: RemoteScopeListingModel] = [:]
        for (scope, listed) in remote.scopes {
            listings[scope] = try ScopeListingBuilder.build(
                secrets: listed.secrets,
                variables: listed.variables,
                rows: rows(in: scope, snapshot: snapshot),
                values: values
            )
        }
        let environments = (remote.environments ?? [:]).values.map { dto in
            RemoteEnvironmentModel(
                githubID: dto.id,
                name: dto.name,
                updatedAt: dto.updatedAt,
                branchPolicy: dto.branchPolicyKind,
                foreignRulesJSON: dto.foreignRulesJSON,
                listing: listings[.environment(named: dto.name)]
            )
        }
        return (RemoteSnapshotModel(repository: listings[.repository], environments: environments), listings)
    }

    /// Local rows that may address `scope` (by an environment's synced name or name).
    private func rows(in scope: RemoteScopeKeyModel, snapshot: RepoSnapshotModel) -> [ConfigItemSnapshotModel] {
        guard let key = scope.environmentKey else { return snapshot.items(in: .repository) }
        let environments = snapshot.environments.filter { $0.syncedNameKey == key || $0.nameKey == key }
        return environments.flatMap { snapshot.items(in: .environment($0.id)) }
    }

    private func checkRemoteBases(
        _ changes: [ConfigChangeModel],
        snapshot: RepoSnapshotModel,
        remote: RemoteListings,
        listings: [RemoteScopeKeyModel: RemoteScopeListingModel],
        ownedTargets: Set<String>,
        remoteChanged: inout Set<String>,
        reasons: inout [String: SyncBlockReason]
    ) {
        let rows = Dictionary(snapshot.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newScopes = Set(changes.compactMap { change -> RemoteScopeKeyModel? in
            switch change.operation {
            case .upsertEnvironment(let upsert) where upsert.isNew: change.scope
            case .renameEnvironment: change.scope
            default: nil
            }
        })
        for change in changes where reasons[change.id] == nil {
            switch change.operation {
            case .createRepository:
                continue
            case .reconcileBranchPatterns where newScopes.contains(change.scope):
                // The environment is created (or renamed into) by this run.
                continue
            case .upsertEnvironment, .reconcileBranchPatterns, .deleteEnvironment, .renameEnvironment:
                guard let environments = remote.environments else {
                    reasons[change.id] = .listingFailed(remote.environmentsError ?? .malformedOutput)
                    continue
                }
                let local = environmentRow(for: change.operation, snapshot: snapshot)
                if RemoteBaseChecker.environmentBaseMoved(change.operation, remote: environments, local: local, ownedTargetKeys: ownedTargets) {
                    remoteChanged.insert(change.id)
                } else if case .upsertEnvironment(let upsert) = change.operation, !upsert.isNew,
                          environments[.environment(named: upsert.name)]?.foreignRulesJSON != nil {
                    reasons[change.id] = .protectionRulesPresent
                } else if case .renameEnvironment(let rename) = change.operation {
                    checkRenameSource(rename, change: change, rows: rows, remote: remote, listings: listings, remoteChanged: &remoteChanged, reasons: &reasons)
                }
            case .setItem, .deleteItem:
                let scope = change.scope
                if let error = remote.scopeErrors[scope] {
                    reasons[change.id] = .listingFailed(error)
                } else if let listing = listings[scope] {
                    let row = change.operation.itemID.flatMap { rows[$0] }
                    if RemoteBaseChecker.itemBaseMoved(change.operation, row: row, listing: listing) {
                        remoteChanged.insert(change.id)
                    }
                } else if scope.environmentKey != nil, !newScopes.contains(scope) {
                    if remote.environments == nil {
                        reasons[change.id] = .listingFailed(remote.environmentsError ?? .malformedOutput)
                    } else {
                        // The environment is gone on GitHub (§7.7 environment deleted).
                        remoteChanged.insert(change.id)
                    }
                }
            }
        }
    }

    /// §7.6: a rename recreates the environment from local values, so a source item changed on
    /// GitHub must be reviewed first.
    private func checkRenameSource(
        _ rename: EnvironmentRenameChangeModel,
        change: ConfigChangeModel,
        rows: [ConfigItemID: ConfigItemSnapshotModel],
        remote: RemoteListings,
        listings: [RemoteScopeKeyModel: RemoteScopeListingModel],
        remoteChanged: inout Set<String>,
        reasons: inout [String: SyncBlockReason]
    ) {
        let source = RemoteScopeKeyModel.environment(named: rename.fromName)
        if let error = remote.scopeErrors[source] {
            reasons[change.id] = .listingFailed(error)
            return
        }
        guard let listing = listings[source] else { return }
        let moved = rows.values.contains { row in
            guard row.scope == .environment(rename.environmentID), let syncedNameKey = row.syncedNameKey else { return false }
            guard let remoteItem = listing.item(kind: row.kind, nameKey: syncedNameKey) else { return !row.isDeleted }
            return RemoteBaseChecker.baseMoved(row: row, remote: remoteItem)
        }
        if moved { remoteChanged.insert(change.id) }
    }

    private func environmentRow(for operation: ConfigChangeOperation, snapshot: RepoSnapshotModel) -> EnvironmentModel? {
        let id: EnvironmentID? = switch operation {
        case .upsertEnvironment(let upsert): upsert.environmentID
        case .renameEnvironment(let rename): rename.environmentID
        case .reconcileBranchPatterns(let patterns): patterns.environmentID
        case .deleteEnvironment(let delete): delete.environmentID
        default: nil
        }
        return id.flatMap(snapshot.environment)
    }

    /// GitHub's per-scope limits against the listed counts plus this run's adds and deletes.
    private func checkCapacity(
        _ changes: [ConfigChangeModel],
        snapshot: RepoSnapshotModel,
        listings: [RemoteScopeKeyModel: RemoteScopeListingModel],
        into reasons: inout [String: SyncBlockReason]
    ) {
        struct Bucket: Hashable {
            let scope: RemoteScopeKeyModel
            let kind: ConfigKind
        }
        var names: [Bucket: Set<String>] = [:]
        for (scope, listing) in listings {
            names[Bucket(scope: scope, kind: .secret)] = Set(listing.secrets.map(\.nameKey))
            names[Bucket(scope: scope, kind: .variable)] = Set(listing.variables.map(\.nameKey))
        }
        for change in changes where reasons[change.id] == nil {
            if case .deleteItem(let delete) = change.operation {
                names[Bucket(scope: delete.scope, kind: delete.kind)]?.remove(delete.key.nameKey)
            }
        }
        for change in changes where reasons[change.id] == nil {
            guard case .setItem(let set) = change.operation else { continue }
            let bucket = Bucket(scope: set.scope, kind: set.kind)
            var current = names[bucket] ?? []
            guard !current.contains(set.key.nameKey) else { continue }
            do {
                try ScopeCapacityValidator.validate(currentCount: current.count, kind: set.kind, level: set.scope.level)
                current.insert(set.key.nameKey)
                names[bucket] = current
            } catch {
                reasons[change.id] = .scopeFull(error)
            }
        }
    }
}

/// The throttle cost of a change (D12): one per write, two for a variable update, and one per
/// pattern a reconcile posts or deletes. Public so VaultData can re-estimate a preflight it
/// narrowed (held share files, v0.9.0).
public enum WriteCostEstimator {
    public static func cost(of change: ConfigChangeModel, snapshot: RepoSnapshotModel) -> Int {
        switch change.operation {
        case .setItem(let set) where set.kind == .variable && !set.isNew:
            Limits.variableUpdateWriteCost
        case .reconcileBranchPatterns(let patterns):
            patterns.desired.filter { !$0.isSynced }.count + patterns.deleted.count
        case .renameEnvironment(let rename):
            Limits.defaultWriteCost + rename.policy.activePatterns.count
        default:
            Limits.defaultWriteCost
        }
    }
}
