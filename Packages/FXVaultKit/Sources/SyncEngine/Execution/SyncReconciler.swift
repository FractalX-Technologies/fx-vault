import Foundation
import GitHubKit
import VaultCore

/// Launch reconciliation of journal rows left `in_flight` (a crash) or `indeterminate` (a timeout,
/// 5xx or network error nobody confirmed) (tasks/todo.md §7.3 "Indeterminate outcomes", D28).
/// Run it after unlock and before a new sync is allowed.
///
/// Each row is checked against a fresh re-list, never against the local clock:
/// - item set: a secret listed with `updatedAt` ≠ the row's `pre_write_updated_at` (or listed at
///   all when that was nil); a variable whose listed fingerprint equals the fingerprint of the
///   current local value, D32-normalized. Confirmed → `reconciled` with `itemPushed` +
///   `itemVerified`. A secret's `itemPushed` carries the fingerprints journaled with the push
///   (``SyncJournalPushModel``), never the current value's: a value edited since then stays
///   pending. A secret row journaled without them (before v7) is closed as `failed`;
/// - item delete: the name is no longer listed → `reconciled` with `itemDeleted`;
/// - environment PUT: B4 shows the environment with the local policy → `environmentSynced`;
/// - environment delete: B3 no longer lists it → `environmentDeleted`;
/// - repository create: ``RepositoryAdoption`` (a journaled "free" lookup, then B2 finds the
///   expected owner and visibility) → `repositoryCreated`; a mismatch is a conflict;
/// - writes that belong to a guided rename only get their journal state (the rename re-runs):
///   the environment PUT (`op = rename_environment`) and the copies into the new name of an
///   environment whose rename is still pending (``isRenameCopy(_:placement:)``);
/// - pattern writes and journaled reads are closed as `failed` (the next reconcile matches
///   GitHub's patterns by name).
///
/// Anything not confirmed becomes `failed`: the change is still pending and the next Sync
/// retries it.
public struct SyncReconciler: Sendable {
    private let schedulers: SyncSchedulerRegistry
    private let persistence: any SyncPersisting
    private let values: any SyncValueProviding
    private let clock: any VaultClock

    public init(
        schedulers: SyncSchedulerRegistry,
        persistence: any SyncPersisting,
        values: any SyncValueProviding,
        clock: any VaultClock
    ) {
        self.schedulers = schedulers
        self.persistence = persistence
        self.values = values
        self.clock = clock
    }

    /// Reconciles every unresolved row of the repositories in `snapshots`. Rows of other
    /// repositories (or accounts without a scheduler) are left for a later launch.
    public func reconcile(_ snapshots: [RepoSnapshotModel]) async throws(SyncError) -> SyncReconciliationModel {
        try values.ensureUnlocked()
        let entries = try persistence.journalEntries(states: SyncJournalOutcomeState.unresolved)
            .sorted { ($0.id ?? SyncJournalEntryID(0)) < ($1.id ?? SyncJournalEntryID(0)) }
        var result = SyncReconciliationModel()
        let byRepository = Dictionary(snapshots.map { ($0.repository.id, $0) }, uniquingKeysWith: { first, _ in first })
        var cache = ListingCache()
        for entry in entries {
            guard let entryID = entry.id,
                  let repositoryID = entry.repositoryID,
                  let snapshot = byRepository[repositoryID],
                  let scheduler = schedulers.scheduler(for: entry.accountLogin)
            else {
                result.unchecked.append(entry)
                continue
            }
            let context = Context(entry: entry, snapshot: snapshot, scheduler: scheduler)
            let decision = try await decide(context, cache: &cache)
            let outcome: SyncJournalOutcomeModel = switch decision.kind {
            case .reconciled: SyncJournalOutcomeModel(state: .reconciled, finishedAt: clock.now)
            case .failed: SyncJournalOutcomeModel(
                state: .failed,
                errorCode: entry.errorCode ?? SyncExecutionConstants.notConfirmedErrorCode,
                finishedAt: clock.now
            )
            case .conflict: SyncJournalOutcomeModel(
                state: .failed,
                errorCode: SyncExecutionConstants.createConflictErrorCode,
                finishedAt: clock.now
            )
            }
            try persistence.commit(SyncCommitModel(
                journal: [SyncJournalUpdateModel(id: entryID, outcome: outcome)],
                effects: decision.effects
            ))
            switch decision.kind {
            case .reconciled: result.reconciled.append(entry)
            case .failed: result.failed.append(entry)
            case .conflict: result.conflicts.append(entry)
            }
        }
        return result
    }

    // MARK: - Decisions

    fileprivate struct Context {
        let entry: SyncJournalEntryModel
        let snapshot: RepoSnapshotModel
        let scheduler: GHCommandScheduler

        var isRenameWrite: Bool {
            entry.op == ConfigChangeKind.renameEnvironment.rawValue
        }

        var repositoryID: RepoID {
            snapshot.repository.id
        }

        func rows(in environmentID: EnvironmentID?) -> [ConfigItemSnapshotModel] {
            snapshot.items(in: ConfigScope(environmentID: environmentID))
        }
    }

    private struct Decision {
        enum Kind {
            case reconciled
            case failed
            case conflict
        }

        var kind: Kind
        var effects: [SyncStateEffectModel] = []

        static let failed = Decision(kind: .failed)
    }

    private func decide(_ context: Context, cache: inout ListingCache) async throws(SyncError) -> Decision {
        let repository = context.snapshot.repository
        guard let ref = try? GHRepoRef(owner: repository.ownerLogin, name: repository.name) else { return .failed }
        switch context.entry.command {
        case .repoCreate:
            return try await decideCreate(context, ref: ref)
        case .secretSet, .variableSet:
            return try await decideSet(context, ref: ref, cache: &cache)
        case .secretDelete, .variableDelete:
            return try await decideDelete(context, ref: ref, cache: &cache)
        case .environmentPut:
            return await decideEnvironmentPut(context, ref: ref)
        case .environmentDelete:
            return await decideEnvironmentDelete(context, ref: ref)
        case .branchPolicyAdd, .branchPolicyDelete, .repoView:
            return .failed
        }
    }

    private func decideCreate(_ context: Context, ref: GHRepoRef) async throws(SyncError) -> Decision {
        let repository = context.snapshot.repository
        let dto: GHRepoDTO
        do {
            dto = try await context.scheduler.viewRepository(ref)
        } catch {
            return .failed
        }
        let history = try persistence.journalEntries(
            repositoryID: repository.id,
            since: clock.now.addingTimeInterval(-Timeouts.syncJournalRetention.timeInterval)
        )
        let request = RepositoryCreateChangeModel(
            ownerLogin: repository.ownerLogin,
            name: repository.name,
            visibility: repository.visibility,
            description: repository.description,
            spec: repository.createSpec
        )
        guard RepositoryAdoption.journalAllowsAdoption(history), RepositoryAdoption.matches(dto, request: request) else {
            return Decision(kind: .conflict)
        }
        guard !repository.existsOnGitHub else { return Decision(kind: .reconciled) }
        return Decision(kind: .reconciled, effects: [
            RepositoryAdoption.effect(repositoryID: repository.id, dto: dto, fallbackName: repository.name),
        ])
    }

    private func decideSet(_ context: Context, ref: GHRepoRef, cache: inout ListingCache) async throws(SyncError) -> Decision {
        guard let key = RemoteItemKeyModel(journalKey: context.entry.targetKey),
              let placement = placement(of: key.scope, in: context.snapshot),
              let listing = try await cache.listing(placement, kind: key.kind, ref: ref, context: context, values: values)
        else { return .failed }
        let row = row(for: key, placement: placement, snapshot: context.snapshot)
        let isRenameWrite = context.isRenameWrite || Self.isRenameCopy(key, placement: placement)
        switch key.kind {
        case .secret:
            let listed = listing.secret(nameKey: key.nameKey)
            guard WriteVerifier.isSecretVerified(listed: listed, preWriteUpdatedAt: context.entry.preWriteUpdatedAt) else {
                return .failed
            }
            guard !isRenameWrite, let row else { return Decision(kind: .reconciled) }
            // A moved `updatedAt` shows that *a* write landed, not which value: record what this
            // push sent. Without its fingerprints nothing proves the row is synced.
            guard let push = context.entry.push else { return .failed }
            return pushedDecision(
                row: row,
                key: key,
                push: push,
                entry: context.entry,
                remoteUpdatedAt: listed?.updatedAt
            )
        case .variable:
            guard let row, let source = try values.value(of: row.id) else { return .failed }
            defer { source.wipe() }
            let expected: Data
            let didNormalize: Bool
            do {
                let normalized = try ValueNormalizer.normalize(source.value)
                defer { normalized.value.wipe() }
                expected = try values.fingerprint(normalized.value, rowID: row.id)
                didNormalize = normalized.didStripTrailingNewlines
            } catch {
                return .failed
            }
            let listed = listing.variable(nameKey: key.nameKey)
            guard WriteVerifier.isVariableVerified(listedFingerprint: listed?.fingerprint(for: row.id), expected: expected) else {
                return .failed
            }
            guard !isRenameWrite else { return Decision(kind: .reconciled) }
            // GitHub holds exactly the current local value (fingerprints matched above).
            let current = SyncJournalPushModel(
                sourceFingerprint: source.fingerprint,
                pushedFingerprint: expected,
                didNormalizeValue: didNormalize
            )
            return pushedDecision(row: row, key: key, push: current, entry: context.entry, remoteUpdatedAt: listed?.updatedAt)
        }
    }

    /// `itemPushed` with `push` as what was sent under the journaled name, and `itemVerified`.
    /// `SyncEffectApplier` records a value edited since the push as still pending.
    private func pushedDecision(
        row: ConfigItemSnapshotModel,
        key: RemoteItemKeyModel,
        push: SyncJournalPushModel,
        entry: SyncJournalEntryModel,
        remoteUpdatedAt: Date?
    ) -> Decision {
        let pushedName = entry.itemName.flatMap { GitHubNameValidator.foldKey($0) == key.nameKey ? $0 : nil } ?? row.name
        let previousName = row.syncedNameKey.flatMap { $0 == key.nameKey ? nil : row.syncedName }
        let pushed = ItemPushedEffectModel(
            itemID: row.id,
            syncedName: pushedName,
            sourceFingerprint: push.sourceFingerprint,
            pushedFingerprint: push.pushedFingerprint,
            didNormalizeValue: push.didNormalizeValue,
            preWriteUpdatedAt: entry.preWriteUpdatedAt,
            detachedPreviousName: previousName
        )
        return Decision(kind: .reconciled, effects: [
            .itemPushed(pushed),
            .itemVerified(itemID: row.id, remoteUpdatedAt: remoteUpdatedAt),
        ])
    }

    /// True for an item write into the new name of an environment whose guided rename is still
    /// pending (synced under another name): a rename copy (§7.6), journaled as a plain set or
    /// delete. Recording it would move the row to the new environment's identity while the
    /// environment is still synced under its old name.
    static func isRenameCopy(_ key: RemoteItemKeyModel, placement: Placement) -> Bool {
        guard let environment = placement.environment, !environment.isDeleted,
              let syncedNameKey = environment.syncedNameKey, syncedNameKey != environment.nameKey
        else { return false }
        return key.scope.environmentKey == environment.nameKey
    }

    private func decideDelete(_ context: Context, ref: GHRepoRef, cache: inout ListingCache) async throws(SyncError) -> Decision {
        guard let key = RemoteItemKeyModel(journalKey: context.entry.targetKey),
              let placement = placement(of: key.scope, in: context.snapshot),
              let listing = try await cache.listing(placement, kind: key.kind, ref: ref, context: context, values: values),
              listing.item(kind: key.kind, nameKey: key.nameKey) == nil
        else { return .failed }
        guard !context.isRenameWrite, !Self.isRenameCopy(key, placement: placement),
              let row = row(for: key, placement: placement, snapshot: context.snapshot), let syncedName = row.syncedName
        else {
            return Decision(kind: .reconciled)
        }
        return Decision(kind: .reconciled, effects: [
            .itemDeleted(ItemDeletedEffectModel(
                itemID: row.id,
                environmentID: placement.environment?.id,
                kind: key.kind,
                syncedName: row.syncedNameKey == key.nameKey ? syncedName : row.name
            )),
        ])
    }

    private func decideEnvironmentPut(_ context: Context, ref: GHRepoRef) async -> Decision {
        guard let scope = RemoteScopeKeyModel(environmentJournalKey: context.entry.targetKey),
              let placement = placement(of: scope, in: context.snapshot),
              let environment = placement.environment
        else { return .failed }
        let found: GHEnvironmentDTO?
        do {
            found = try await context.scheduler.environment(ref, named: placement.remoteName ?? environment.name)
        } catch {
            return .failed
        }
        guard let found, found.branchPolicyKind == environment.branchPolicy.kind else { return .failed }
        guard !context.isRenameWrite else { return Decision(kind: .reconciled) }
        return Decision(kind: .reconciled, effects: [
            .environmentSynced(EnvironmentSyncedEffectModel(
                environmentID: environment.id,
                syncedName: found.name,
                githubID: found.id,
                policy: found.branchPolicyKind,
                foreignRulesJSON: found.foreignRulesJSON,
                remoteUpdatedAt: found.updatedAt
            )),
        ])
    }

    private func decideEnvironmentDelete(_ context: Context, ref: GHRepoRef) async -> Decision {
        guard let scope = RemoteScopeKeyModel(environmentJournalKey: context.entry.targetKey) else { return .failed }
        let environments: [GHEnvironmentDTO]
        do {
            environments = try await context.scheduler.listEnvironments(ref)
        } catch {
            return .failed
        }
        guard !environments.contains(where: { RemoteScopeKeyModel.environment(named: $0.name) == scope }) else { return .failed }
        let tombstone = context.snapshot.environments.first { $0.isDeleted && $0.syncedNameKey == scope.environmentKey }
        return Decision(kind: .reconciled, effects: tombstone.map { [.environmentDeleted(environmentID: $0.id)] } ?? [])
    }

    // MARK: - Local lookups

    /// A remote scope resolved to the local environment (nil at repository level).
    struct Placement: Hashable {
        let scope: RemoteScopeKeyModel
        let environment: EnvironmentModel?
        /// The `--env` name: the environment's synced name, else its name; nil at repository level.
        let remoteName: String?
    }

    private func placement(of scope: RemoteScopeKeyModel, in snapshot: RepoSnapshotModel) -> Placement? {
        guard let key = scope.environmentKey else {
            return Placement(scope: scope, environment: nil, remoteName: nil)
        }
        let environment = snapshot.environments.first { !$0.isDeleted && $0.syncedNameKey == key }
            ?? snapshot.environments.first { !$0.isDeleted && $0.nameKey == key }
            ?? snapshot.environments.first { $0.syncedNameKey == key }
        guard let environment else { return nil }
        let remoteName = environment.syncedNameKey == key ? environment.syncedName : environment.name
        return Placement(scope: scope, environment: environment, remoteName: remoteName)
    }

    private func row(for key: RemoteItemKeyModel, placement: Placement, snapshot: RepoSnapshotModel) -> ConfigItemSnapshotModel? {
        let rows = snapshot.items(in: ConfigScope(environmentID: placement.environment?.id)).filter { $0.kind == key.kind }
        return rows.first { $0.nameKey == key.nameKey && !$0.isDeleted }
            ?? rows.first { $0.syncedNameKey == key.nameKey }
    }
}

/// Listings fetched once per scope and kind during one reconciliation.
private struct ListingCache {
    private struct Key: Hashable {
        let repositoryID: RepoID
        let scope: RemoteScopeKeyModel
        let kind: ConfigKind
    }

    private var listings: [Key: RemoteScopeListingModel?] = [:]

    mutating func listing(
        _ placement: SyncReconciler.Placement,
        kind: ConfigKind,
        ref: GHRepoRef,
        context: SyncReconciler.Context,
        values: any SyncValueProviding
    ) async throws(SyncError) -> RemoteScopeListingModel? {
        let key = Key(repositoryID: context.repositoryID, scope: placement.scope, kind: kind)
        if let cached = listings[key] { return cached }
        let rows = context.rows(in: placement.environment?.id)
        var listing: RemoteScopeListingModel?
        do {
            switch kind {
            case .secret:
                let secrets = try await context.scheduler.listSecrets(ref, environment: placement.remoteName)
                listing = try? ScopeListingBuilder.build(secrets: secrets, variables: [], rows: rows, values: values)
            case .variable:
                let variables = try await context.scheduler.listVariables(ref, environment: placement.remoteName)
                listing = try ScopeListingBuilder.build(secrets: [], variables: variables, rows: rows, values: values)
            }
        } catch {
            listing = nil
        }
        listings[key] = .some(listing)
        return listing
    }
}

/// The outcome of ``SyncReconciler/reconcile(_:)``.
public struct SyncReconciliationModel: Sendable, Hashable {
    /// Confirmed on GitHub and recorded.
    public var reconciled: [SyncJournalEntryModel] = []
    /// Not confirmed: closed as `failed`, the change stays pending.
    public var failed: [SyncJournalEntryModel] = []
    /// `gh repo create` found a repository that is not provably ours (§7.3): the user decides.
    public var conflicts: [SyncJournalEntryModel] = []
    /// Rows of repositories or accounts not available now; left unresolved.
    public var unchecked: [SyncJournalEntryModel] = []

    public init() {}
}
