import CryptoKit
import Foundation
import os
import VaultCore

/// An in-memory ``SyncPersisting`` and ``SyncValueProviding`` for tests and previews
/// (tasks/todo.md §12.2), like `FakeCommandRunner`.
///
/// It is also the reference for VaultData: ``commit(_:)`` applies every
/// ``SyncStateEffectModel`` to the stored snapshots exactly as documented on the effect.
/// Values are kept as plaintext `Data` and fingerprints are SHA-256 over the row id and the
/// value: **test data only**, never use it with real secrets.
public final class InMemorySyncVault: SyncPersisting, SyncValueProviding, Sendable {
    private struct State: Sendable {
        var order: [RepoID] = []
        var snapshots: [RepoID: RepoSnapshotModel] = [:]
        var values: [ConfigItemID: Data] = [:]
        var syncedValues: [ConfigItemID: Data] = [:]
        var journal: [SyncJournalEntryModel] = []
        var nextJournalID: Int64 = 1
        var commits: [SyncCommitModel] = []
        var isLocked = false
        /// Commits left before ``commit(_:)`` starts failing (nil = never).
        var commitsBeforeFailure: Int?
        var valueReads = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let clock: any VaultClock

    /// - Parameters:
    ///   - snapshots: the repositories, in order.
    ///   - values: plaintext local values by row (test data).
    ///   - clock: stamps rows created by effects.
    public init(snapshots: [RepoSnapshotModel] = [], values: [ConfigItemID: String] = [:], clock: any VaultClock = SystemClock()) {
        self.clock = clock
        state.withLock { state in
            for snapshot in snapshots {
                state.order.append(snapshot.repository.id)
                state.snapshots[snapshot.repository.id] = snapshot
            }
            state.values = values.mapValues { Data($0.utf8) }
        }
    }

    // MARK: - Fingerprints

    /// The fake row-bound fingerprint: SHA-256(row id bytes ‖ value).
    public static func fingerprint(_ value: some Collection<UInt8>, rowID: ConfigItemID) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data(rowID.bytes))
        hasher.update(data: Data(value))
        return Data(hasher.finalize())
    }

    /// ``fingerprint(_:rowID:)`` of a UTF-8 string.
    public static func fingerprint(_ value: String, rowID: ConfigItemID) -> Data {
        fingerprint(Data(value.utf8), rowID: rowID)
    }

    // MARK: - Test controls and inspection

    /// Every repository, in insertion order.
    public var snapshots: [RepoSnapshotModel] {
        state.withLock { state in state.order.compactMap { state.snapshots[$0] } }
    }

    public func snapshot(_ id: RepoID) -> RepoSnapshotModel? {
        state.withLock { $0.snapshots[id] }
    }

    public func item(_ id: ConfigItemID) -> ConfigItemSnapshotModel? {
        state.withLock { state in state.snapshots.values.lazy.compactMap { $0.items.first { $0.id == id } }.first }
    }

    public func environment(_ id: EnvironmentID) -> EnvironmentModel? {
        state.withLock { state in state.snapshots.values.lazy.compactMap { $0.environment(id) }.first }
    }

    /// The plaintext local value (test assertions).
    public func storedValue(of id: ConfigItemID) -> String? {
        state.withLock { $0.values[id].map { String(decoding: $0, as: UTF8.self) } }
    }

    /// The plaintext synced value (test assertions).
    public func storedSyncedValue(of id: ConfigItemID) -> String? {
        state.withLock { $0.syncedValues[id].map { String(decoding: $0, as: UTF8.self) } }
    }

    /// Replaces a local value (an edit during a run); nil makes it missing.
    public func setValue(_ value: String?, for id: ConfigItemID) {
        state.withLock { state in
            state.values[id] = value.map { Data($0.utf8) }
            Self.updateRow(id, in: &state) { $0.valueFingerprint = value.map { Self.fingerprint($0, rowID: id) } }
        }
    }

    /// Edits a repository's rows in place (a user edit between runs).
    public func updateSnapshot(_ id: RepoID, _ body: (inout RepoSnapshotModel) -> Void) {
        state.withLockUnchecked { state in
            guard var snapshot = state.snapshots[id] else { return }
            body(&snapshot)
            state.snapshots[id] = snapshot
        }
    }

    /// Every journal row, in append order.
    public var journal: [SyncJournalEntryModel] {
        state.withLock { $0.journal }
    }

    /// Every commit, in order.
    public var commits: [SyncCommitModel] {
        state.withLock { $0.commits }
    }

    /// Number of decrypted value reads.
    public var valueReadCount: Int {
        state.withLock { $0.valueReads }
    }

    /// Appends a journal row as a past run left it (for reconciliation tests).
    @discardableResult
    public func seedJournal(_ entry: SyncJournalEntryModel) -> SyncJournalEntryID {
        state.withLock { state in Self.append(entry, to: &state) }
    }

    /// Simulates the vault locking (values and fingerprints throw ``SyncError/locked``).
    public func lock() {
        state.withLock { $0.isLocked = true }
    }

    public func unlock() {
        state.withLock { $0.isLocked = false }
    }

    /// Makes ``commit(_:)`` throw ``SyncError/persistenceFailed`` after `count` more commits.
    public func failCommits(after count: Int) {
        state.withLock { $0.commitsBeforeFailure = count }
    }

    // MARK: - SyncPersisting

    public func appendJournal(_ entry: SyncJournalEntryModel) throws(SyncError) -> SyncJournalEntryID {
        state.withLock { state in Self.append(entry, to: &state) }
    }

    public func commit(_ commit: SyncCommitModel) throws(SyncError) {
        let now = clock.now
        let failed = state.withLock { state -> Bool in
            if let remaining = state.commitsBeforeFailure {
                if remaining <= 0 { return true }
                state.commitsBeforeFailure = remaining - 1
            }
            for update in commit.journal {
                guard let index = state.journal.firstIndex(where: { $0.id == update.id }) else { continue }
                state.journal[index].state = update.outcome.state
                state.journal[index].exitCode = update.outcome.exitCode
                state.journal[index].errorCode = update.outcome.errorCode
                state.journal[index].finishedAt = update.outcome.finishedAt
            }
            for effect in commit.effects {
                Self.apply(effect, to: &state, now: now)
            }
            state.commits.append(commit)
            return false
        }
        if failed { throw .persistenceFailed }
    }

    public func journalEntries(states: Set<SyncJournalOutcomeState>) throws(SyncError) -> [SyncJournalEntryModel] {
        state.withLock { $0.journal.filter { states.contains($0.state) } }
    }

    public func journalEntries(repositoryID: RepoID, since: Date) throws(SyncError) -> [SyncJournalEntryModel] {
        state.withLock { $0.journal.filter { $0.repositoryID == repositoryID && $0.startedAt >= since } }
    }

    public func writeStartTimes(accountLogin: String, since: Date) throws(SyncError) -> [Date] {
        let login = OwnerLoginValidator.foldKey(accountLogin)
        return state.withLock { state in
            state.journal
                .filter { $0.isWrite && OwnerLoginValidator.foldKey($0.accountLogin) == login && $0.startedAt >= since }
                .map(\.startedAt)
        }
    }

    // MARK: - SyncValueProviding

    public func ensureUnlocked() throws(SyncError) {
        if state.withLock({ $0.isLocked }) { throw .locked }
    }

    public func value(of itemID: ConfigItemID) throws(SyncError) -> SyncItemValueModel? {
        let read = state.withLock { state -> Data?? in
            if state.isLocked { return nil }
            state.valueReads += 1
            return .some(state.values[itemID])
        }
        guard let read else { throw .locked }
        guard var data = read else { return nil }
        let fingerprint = Self.fingerprint(data, rowID: itemID)
        return SyncItemValueModel(value: SecretBytes(wipingSource: &data), fingerprint: fingerprint)
    }

    public func fingerprint(_ value: SecretBytes, rowID: ConfigItemID) throws(SyncError) -> Data {
        try ensureUnlocked()
        return value.withUnsafeBytes { Self.fingerprint(Array($0), rowID: rowID) }
    }

    // MARK: - Effects (the reference semantics)

    private static func append(_ entry: SyncJournalEntryModel, to state: inout State) -> SyncJournalEntryID {
        let id = SyncJournalEntryID(state.nextJournalID)
        state.nextJournalID += 1
        var stored = entry
        stored.id = id
        state.journal.append(stored)
        return id
    }

    private static func apply(_ effect: SyncStateEffectModel, to state: inout State, now: Date) {
        switch effect {
        case .repositoryCreated(let created):
            updateRepository(created.repositoryID, in: &state) { repository in
                repository.githubID = created.githubID
                repository.ownerLogin = created.ownerLogin
                repository.name = created.name
                repository.visibility = created.visibility
                repository.defaultBranch = created.defaultBranch
                repository.hasAdmin = created.hasAdmin
                repository.hasPush = created.hasPush
                repository.createdAtGitHub = created.createdAt
            }
        case .repositoryPlanGated(let repositoryID):
            updateRepository(repositoryID, in: &state) { $0.isEnvPlanGated = true }
        case .environmentSynced(let synced):
            updateEnvironment(synced.environmentID, in: &state) { apply(synced, to: &$0) }
        case .environmentRenamed(let renamed):
            applyRename(renamed, to: &state, now: now)
        case .environmentDeleted(let environmentID):
            for id in state.order {
                state.snapshots[id]?.environments.removeAll { $0.id == environmentID }
                state.snapshots[id]?.items.removeAll { $0.scope == .environment(environmentID) }
            }
        case .patternsUnsynced(let environmentID):
            updateEnvironment(environmentID, in: &state) { environment in
                guard case .custom(let patterns) = environment.branchPolicy else { return }
                environment.branchPolicy = .custom(patterns.filter { !$0.isDeleted }.map { pattern in
                    var pattern = pattern
                    pattern.githubPolicyID = nil
                    return pattern
                })
            }
        case .patternSynced(let environmentID, let patternID, let githubPolicyID):
            updatePatterns(environmentID, in: &state) { patterns in
                patterns.indices.filter { patterns[$0].id == patternID }.forEach { patterns[$0].githubPolicyID = githubPolicyID }
            }
        case .patternRemoved(let environmentID, let patternID):
            updatePatterns(environmentID, in: &state) { $0.removeAll { $0.id == patternID } }
        case .itemPreWriteBaseline(let itemID, let updatedAt):
            updateRow(itemID, in: &state) { $0.preWriteUpdatedAt = updatedAt }
        case .itemPushed(let pushed):
            applyPush(pushed, to: &state)
        case .itemVerified(let itemID, let remoteUpdatedAt):
            updateRow(itemID, in: &state) { row in
                row.verifyState = .verified
                row.remoteUpdatedAt = remoteUpdatedAt
                if row.provenance == .share { row.provenance = .local }
            }
        case .itemVerificationExpired(let itemID, let forcePush):
            updateRow(itemID, in: &state) { row in
                row.verifyState = .verified
                guard forcePush else { return }
                row.forcePush = true
                if let baseline = row.preWriteUpdatedAt { row.remoteUpdatedAt = baseline }
            }
        case .itemDeleted(let deleted):
            applyDelete(deleted, to: &state)
        }
    }

    private static func apply(_ synced: EnvironmentSyncedEffectModel, to environment: inout EnvironmentModel) {
        environment.syncedName = synced.syncedName
        environment.githubEnvID = synced.githubID
        environment.syncedBranchPolicy = synced.policy
        environment.foreignRulesJSON = synced.foreignRulesJSON
        environment.remoteUpdatedAt = synced.remoteUpdatedAt
    }

    private static func applyRename(_ renamed: EnvironmentRenamedEffectModel, to state: inout State, now: Date) {
        for id in state.order {
            guard var snapshot = state.snapshots[id],
                  let index = snapshot.environments.firstIndex(where: { $0.id == renamed.synced.environmentID })
            else { continue }
            apply(renamed.synced, to: &snapshot.environments[index])
            let previousPolicy: DeploymentBranchPolicyModel = switch renamed.previousPolicy {
            case .protected: .protectedBranches
            case .custom: .custom([])
            case .all, nil: .all
            }
            snapshot.environments.append(EnvironmentModel(
                repositoryID: snapshot.repository.id,
                name: renamed.previousName,
                syncedName: renamed.previousName,
                isDeleted: true,
                branchPolicy: previousPolicy,
                syncedBranchPolicy: renamed.previousPolicy,
                githubEnvID: renamed.previousGitHubID,
                createdAt: now,
                updatedAt: now
            ))
            state.snapshots[id] = snapshot
        }
    }

    private static func applyPush(_ pushed: ItemPushedEffectModel, to state: inout State) {
        guard let row = findRow(pushed.itemID, in: state) else { return }
        if let previous = pushed.detachedPreviousName {
            let tombstone = ConfigItemSnapshotModel(
                scope: row.scope,
                kind: row.kind,
                name: previous,
                valueFingerprint: row.kind == .variable ? row.syncedFingerprint : nil,
                isDeleted: true,
                syncedName: previous,
                hasSyncedValue: row.hasSyncedValue,
                syncedFingerprint: row.syncedFingerprint,
                remoteUpdatedAt: row.remoteUpdatedAt
            )
            if let synced = state.syncedValues[row.id] {
                state.syncedValues[tombstone.id] = synced
                if row.kind == .variable { state.values[tombstone.id] = synced }
            }
            insertRow(tombstone, after: row.id, in: &state)
        }
        let unchanged = row.valueFingerprint == pushed.sourceFingerprint
        let pushedValue = unchanged ? state.values[row.id].map(normalized) : nil
        state.syncedValues[row.id] = pushedValue
        if pushed.didNormalizeValue, unchanged {
            state.values[row.id] = pushedValue
        }
        updateRow(pushed.itemID, in: &state) { row in
            row.syncedName = pushed.syncedName
            row.syncedFingerprint = pushed.pushedFingerprint
            row.hasSyncedValue = pushedValue != nil
            row.forcePush = false
            row.forcePushRequestedAt = nil
            row.verifyState = .pending
            row.preWriteUpdatedAt = pushed.preWriteUpdatedAt
            if pushed.didNormalizeValue, unchanged {
                row.valueFingerprint = pushed.pushedFingerprint
            }
        }
    }

    private static func applyDelete(_ deleted: ItemDeletedEffectModel, to state: inout State) {
        for id in state.order {
            guard var snapshot = state.snapshots[id] else { continue }
            if let row = snapshot.items.first(where: { $0.id == deleted.itemID }) {
                let environmentDeleted = row.scope.environmentID.flatMap { snapshot.environment($0)?.isDeleted } ?? false
                if row.isDeleted || environmentDeleted {
                    snapshot.items.removeAll { $0.id == row.id }
                } else {
                    let key = GitHubNameValidator.foldKey(deleted.syncedName)
                    snapshot.items.removeAll { candidate in
                        candidate.isDeleted && candidate.kind == deleted.kind && candidate.scope == row.scope
                            && candidate.syncedNameKey == key
                    }
                }
                state.snapshots[id] = snapshot
            }
        }
    }

    private static func normalized(_ data: Data) -> Data {
        var bytes = data
        while let last = bytes.last, last == UInt8(ascii: "\n") || last == UInt8(ascii: "\r") {
            bytes.removeLast()
        }
        return bytes
    }

    // MARK: - Row helpers

    private static func findRow(_ id: ConfigItemID, in state: State) -> ConfigItemSnapshotModel? {
        for repository in state.order {
            if let row = state.snapshots[repository]?.items.first(where: { $0.id == id }) { return row }
        }
        return nil
    }

    private static func updateRow(_ id: ConfigItemID, in state: inout State, _ body: (inout ConfigItemSnapshotModel) -> Void) {
        for repository in state.order {
            guard let index = state.snapshots[repository]?.items.firstIndex(where: { $0.id == id }) else { continue }
            if var snapshot = state.snapshots[repository] {
                body(&snapshot.items[index])
                state.snapshots[repository] = snapshot
            }
        }
    }

    private static func insertRow(_ row: ConfigItemSnapshotModel, after id: ConfigItemID, in state: inout State) {
        for repository in state.order {
            guard var snapshot = state.snapshots[repository],
                  let index = snapshot.items.firstIndex(where: { $0.id == id })
            else { continue }
            snapshot.items.insert(row, at: snapshot.items.index(after: index))
            state.snapshots[repository] = snapshot
        }
    }

    private static func updateRepository(_ id: RepoID, in state: inout State, _ body: (inout RepoModel) -> Void) {
        guard var snapshot = state.snapshots[id] else { return }
        body(&snapshot.repository)
        state.snapshots[id] = snapshot
    }

    private static func updateEnvironment(_ id: EnvironmentID, in state: inout State, _ body: (inout EnvironmentModel) -> Void) {
        for repository in state.order {
            guard var snapshot = state.snapshots[repository],
                  let index = snapshot.environments.firstIndex(where: { $0.id == id })
            else { continue }
            body(&snapshot.environments[index])
            state.snapshots[repository] = snapshot
        }
    }

    private static func updatePatterns(_ id: EnvironmentID, in state: inout State, _ body: (inout [BranchPatternModel]) -> Void) {
        updateEnvironment(id, in: &state) { environment in
            guard case .custom(var patterns) = environment.branchPolicy else { return }
            body(&patterns)
            environment.branchPolicy = .custom(patterns)
        }
    }
}
