import Foundation
import FXVaultTestSupport
import SyncEngine
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// ``VaultSyncPersistence`` and ``VaultSyncValues`` against the effect semantics documented on
/// `SyncStateEffectModel` (SyncEngine's `InMemorySyncVault` is the reference).
@Suite("VaultSyncPersistence", .timeLimit(.minutes(1)))
struct VaultSyncPersistenceTests {
    private func harness() async throws -> SyncHarness {
        let harness = try await SyncHarness.make()
        try await harness.importRepository()
        return harness
    }

    private func persistence(_ harness: SyncHarness) -> VaultSyncPersistence {
        VaultSyncPersistence(session: harness.session, clock: harness.clock)
    }

    private func entry(_ harness: SyncHarness, command: SyncJournalCommand = .secretSet, name: String = "FXV_A") throws -> SyncJournalEntryModel {
        SyncJournalEntryModel(
            runID: SyncRunID(),
            accountLogin: SyncFixture.login,
            repositoryID: try harness.repository().id,
            op: ConfigChangeKind.setSecret.rawValue,
            command: command,
            scopeLabel: SyncExecutionConstants.repositoryScopeLabel,
            targetKey: RemoteItemKeyModel(scope: .repository, kind: .secret, name: name).journalKey,
            itemName: name,
            startedAt: harness.clock.now
        )
    }

    // MARK: - Journal

    @Test func journalRowsRoundTripThroughTheStore() async throws {
        let harness = try await harness()
        let persistence = persistence(harness)
        let repositoryID = try harness.repository().id
        let id = try persistence.appendJournal(try entry(harness))
        let read = try persistence.appendJournal(try entry(harness, command: .repoView))
        #expect(id < read)

        let finished = harness.clock.now
        try persistence.commit(SyncCommitModel(journal: [
            SyncJournalUpdateModel(id: id, outcome: SyncJournalOutcomeModel(state: .succeeded, exitCode: 0, finishedAt: finished)),
        ]))

        let succeeded = try persistence.journalEntries(states: [.succeeded])
        #expect(succeeded.map(\.id) == [id])
        #expect(succeeded.first?.exitCode == 0)
        #expect(succeeded.first?.finishedAt == DatabaseTimestamp.roundTripped(finished))
        #expect(try persistence.journalEntries(states: [.inFlight]).map(\.id) == [read])
        #expect(try persistence.journalEntries(repositoryID: repositoryID, since: .distantPast).count == 2)
        #expect(try persistence.journalEntries(repositoryID: RepoID(), since: .distantPast).isEmpty)
        // Only writes count toward the throttle (repo.view is a read).
        #expect(try persistence.writeStartTimes(accountLogin: "USER-A", since: .distantPast).count == 1)
    }

    @Test func anOutcomeForAPrunedRowIsIgnored() async throws {
        let harness = try await harness()
        try persistence(harness).commit(SyncCommitModel(journal: [
            SyncJournalUpdateModel(id: SyncJournalEntryID(999), outcome: SyncJournalOutcomeModel(state: .failed, finishedAt: harness.clock.now)),
        ]))
    }

    // MARK: - itemPushed

    @Test func pushRecordsTheSyncedValueAndWaitsForVerification() async throws {
        let harness = try await harness()
        let id = try harness.add("FXV_PUSHED", kind: .secret, value: "pushed-value")
        let fingerprint = try harness.fingerprint("pushed-value", rowID: id)
        let baseline = harness.clock.now
        try persistence(harness).commit(SyncCommitModel(effects: [
            .itemPushed(ItemPushedEffectModel(
                itemID: id,
                syncedName: "FXV_PUSHED",
                sourceFingerprint: fingerprint,
                pushedFingerprint: fingerprint,
                didNormalizeValue: false,
                preWriteUpdatedAt: baseline,
                detachedPreviousName: nil
            )),
        ]))
        let record = try harness.record(id)
        #expect(record.syncedName == "FXV_PUSHED")
        #expect(record.syncedFingerprint == fingerprint)
        #expect(record.verifyState == .pending)
        #expect(record.preWriteUpdatedAt == DatabaseTimestamp.roundTripped(baseline))
        #expect(try harness.syncedValue(id) == "pushed-value")
        #expect(record.state.model.syncStatus == .synced)
    }

    @Test func pushOfAValueEditedDuringTheRunKeepsNoSyncedCopy() async throws {
        let harness = try await harness()
        let id = try harness.add("FXV_EDITED", kind: .variable, value: "before")
        let source = try harness.fingerprint("before", rowID: id)
        try harness.config.editValue(id, value: SecretBytes(utf8: "after"))
        try persistence(harness).commit(SyncCommitModel(effects: [
            .itemPushed(ItemPushedEffectModel(
                itemID: id,
                syncedName: "FXV_EDITED",
                sourceFingerprint: source,
                pushedFingerprint: source,
                didNormalizeValue: false,
                preWriteUpdatedAt: nil,
                detachedPreviousName: nil
            )),
        ]))
        let record = try harness.record(id)
        #expect(record.syncedValueCiphertext == nil)
        #expect(record.syncedFingerprint == source)
        #expect(try harness.value(id) == "after")
        // The edit is still pending as a modify.
        #expect(record.state.model.syncStatus == .modified)
    }

    @Test func normalizedPushMakesLocalEqualGitHub() async throws {
        let harness = try await harness()
        // A variable imported from GitHub ending in a newline (D32: stored as listed).
        let id = try harness.insertRow("FXV_PEM", kind: .variable, value: "line-1\nline-2\n", syncedValue: "line-1\nline-2\n", syncedName: "FXV_PEM")
        let source = try harness.fingerprint("line-1\nline-2\n", rowID: id)
        let pushed = try harness.fingerprint("line-1\nline-2", rowID: id)
        try persistence(harness).commit(SyncCommitModel(effects: [
            .itemPushed(ItemPushedEffectModel(
                itemID: id,
                syncedName: "FXV_PEM",
                sourceFingerprint: source,
                pushedFingerprint: pushed,
                didNormalizeValue: true,
                preWriteUpdatedAt: nil,
                detachedPreviousName: nil
            )),
        ]))
        let record = try harness.record(id)
        #expect(try harness.value(id) == "line-1\nline-2")
        #expect(try harness.syncedValue(id) == "line-1\nline-2")
        #expect(record.valueFingerprint == pushed)
        #expect(record.syncedFingerprint == pushed)
    }

    @Test func renamePushDetachesTheOldNameUntilItsDeleteIsConfirmed() async throws {
        let harness = try await harness()
        let id = try harness.insertRow("FXV_OLD", kind: .variable, value: "kept", syncedValue: "kept", syncedName: "FXV_OLD")
        _ = try harness.config.renameItem(id, to: "FXV_NEW")
        let fingerprint = try harness.fingerprint("kept", rowID: id)
        let persistence = persistence(harness)
        try persistence.commit(SyncCommitModel(effects: [
            .itemPushed(ItemPushedEffectModel(
                itemID: id,
                syncedName: "FXV_NEW",
                sourceFingerprint: fingerprint,
                pushedFingerprint: fingerprint,
                didNormalizeValue: false,
                preWriteUpdatedAt: nil,
                detachedPreviousName: "FXV_OLD"
            )),
        ]))

        let tombstone = try #require(try harness.states().first { $0.isDeleted })
        #expect(tombstone.name == "FXV_OLD")
        #expect(tombstone.syncedName == "FXV_OLD")
        #expect(tombstone.id != id)
        // Re-sealed for the tombstone's own identity.
        #expect(try harness.syncedValue(tombstone.id) == "kept")
        #expect(try harness.value(tombstone.id) == "kept")
        #expect(try harness.record(id).syncedName == "FXV_NEW")
        let changeSet = try #require(try harness.config.changeSet(repositoryID: harness.repository().id))
        #expect(changeSet.changes.map(\.kind) == [.deleteVariable])

        try persistence.commit(SyncCommitModel(effects: [
            .itemDeleted(ItemDeletedEffectModel(itemID: id, environmentID: nil, kind: .variable, syncedName: "FXV_OLD")),
        ]))
        #expect(try harness.states().map(\.name) == ["FXV_NEW"])
        #expect(try harness.pendingCount() == 0)
    }

    @Test func confirmedDeleteRemovesTheTombstone() async throws {
        let harness = try await harness()
        let id = try harness.insertRow("FXV_GONE", kind: .secret, value: nil, syncedName: "FXV_GONE")
        try harness.config.deleteItem(id)
        #expect(try harness.record(id).isDeleted)
        try persistence(harness).commit(SyncCommitModel(effects: [
            .itemDeleted(ItemDeletedEffectModel(itemID: id, environmentID: nil, kind: .secret, syncedName: "FXV_GONE")),
        ]))
        #expect(try harness.store.fetchItemRecord(id: id) == nil)
    }

    @Test func verificationConfirmsAShareAndExpiryForcesARepush() async throws {
        let harness = try await harness()
        let shared = try harness.insertRow("FXV_SHARED", kind: .secret, value: "v", syncedValue: "v", syncedName: "FXV_SHARED", provenance: .share)
        let expired = try harness.insertRow("FXV_EXPIRED", kind: .secret, value: "w", syncedValue: "w", syncedName: "FXV_EXPIRED")
        let listedAt = harness.clock.now
        try persistence(harness).commit(SyncCommitModel(effects: [
            .itemVerified(itemID: shared, remoteUpdatedAt: listedAt),
            .itemVerificationExpired(itemID: expired, forcePush: true),
            .itemPreWriteBaseline(itemID: expired, updatedAt: listedAt),
        ]))
        let verified = try harness.record(shared)
        #expect(verified.provenance == .local)
        #expect(verified.shareOrigin == nil)
        #expect(verified.remoteUpdatedAt == DatabaseTimestamp.roundTripped(listedAt))
        let forced = try harness.record(expired)
        #expect(forced.forcePush)
        #expect(forced.verifyState == .verified)
        #expect(forced.preWriteUpdatedAt == DatabaseTimestamp.roundTripped(listedAt))
    }

    // MARK: - Repositories and environments

    @Test func repositoryAndEnvironmentBookkeeping() async throws {
        let harness = try await harness()
        let repository = try harness.repository()
        let environmentID = try harness.config.createEnvironment(
            in: repository.id,
            name: "production",
            policy: .custom([BranchPatternDraftModel(pattern: "release/*", type: .branch)])
        )
        let pattern = try #require(try harness.store.fetchPatterns(environmentID: environmentID).first)
        let persistence = persistence(harness)
        try persistence.commit(SyncCommitModel(effects: [
            .repositoryPlanGated(repositoryID: repository.id),
            .environmentSynced(EnvironmentSyncedEffectModel(
                environmentID: environmentID,
                syncedName: "production",
                githubID: 77,
                policy: .custom,
                foreignRulesJSON: nil,
                remoteUpdatedAt: harness.clock.now
            )),
            .patternSynced(environmentID: environmentID, patternID: pattern.id, githubPolicyID: 501),
        ]))
        #expect(try harness.repository().isEnvPlanGated)
        let synced = try #require(try harness.environment("production"))
        #expect(synced.githubEnvID == 77)
        #expect(synced.syncedBranchPolicy == .custom)
        #expect(try harness.store.fetchPatterns(environmentID: environmentID).first?.githubPolicyID == 501)

        try persistence.commit(SyncCommitModel(effects: [.patternsUnsynced(environmentID: environmentID)]))
        #expect(try harness.store.fetchPatterns(environmentID: environmentID).first?.githubPolicyID == nil)

        try persistence.commit(SyncCommitModel(effects: [.patternRemoved(environmentID: environmentID, patternID: pattern.id)]))
        #expect(try harness.store.fetchPatterns(environmentID: environmentID).isEmpty)
    }

    @Test func verifiedRenameLeavesATombstoneForTheOldEnvironment() async throws {
        let harness = try await harness()
        let repository = try harness.repository()
        let environmentID = try harness.config.createEnvironment(in: repository.id, name: "staging")
        let persistence = persistence(harness)
        try persistence.commit(SyncCommitModel(effects: [
            .environmentSynced(EnvironmentSyncedEffectModel(environmentID: environmentID, syncedName: "staging", githubID: 10, policy: .all, foreignRulesJSON: nil, remoteUpdatedAt: nil)),
        ]))
        try harness.config.renameEnvironment(environmentID, to: "stage")
        try persistence.commit(SyncCommitModel(effects: [
            .environmentRenamed(EnvironmentRenamedEffectModel(
                synced: EnvironmentSyncedEffectModel(environmentID: environmentID, syncedName: "stage", githubID: 11, policy: .all, foreignRulesJSON: nil, remoteUpdatedAt: nil),
                previousName: "staging",
                previousGitHubID: 10,
                previousPolicy: .all
            )),
        ]))
        let moved = try #require(try harness.environment("stage"))
        #expect(moved.id == environmentID)
        #expect(moved.githubEnvID == 11)
        let tombstone = try #require(try harness.environment("staging"))
        #expect(tombstone.isDeleted)
        #expect(tombstone.githubEnvID == 10)
        let changeSet = try #require(try harness.config.changeSet(repositoryID: repository.id))
        #expect(changeSet.changes.map(\.kind) == [.deleteEnvironment])

        try persistence.commit(SyncCommitModel(effects: [.environmentDeleted(environmentID: tombstone.id)]))
        #expect(try harness.environment("staging") == nil)
    }

    @Test func repositoryCreatedTakesGitHubsIdentity() async throws {
        let harness = try await harness()
        let repository = try harness.repository()
        try persistence(harness).commit(SyncCommitModel(effects: [
            .repositoryCreated(RepositoryCreatedEffectModel(
                repositoryID: repository.id,
                githubID: "R_created",
                ownerLogin: SyncFixture.owner,
                name: SyncFixture.repoName,
                visibility: .public,
                defaultBranch: "main",
                hasAdmin: true,
                hasPush: true,
                createdAt: harness.clock.now
            )),
        ]))
        let created = try harness.repository()
        #expect(created.githubID == "R_created")
        #expect(created.visibility == .public)
        #expect(created.defaultBranch == "main")
    }

    // MARK: - Locking

    @Test func bookkeepingIsRecordedWhileLockedButPushesAreNot() async throws {
        let harness = try await harness()
        let id = try harness.add("FXV_LATE", kind: .secret, value: "late")
        let fingerprint = try harness.fingerprint("late", rowID: id)
        let persistence = persistence(harness)
        let entryID = try persistence.appendJournal(try entry(harness, name: "FXV_LATE"))
        harness.manager.lock()

        try persistence.commit(SyncCommitModel(
            journal: [SyncJournalUpdateModel(id: entryID, outcome: SyncJournalOutcomeModel(state: .failed, finishedAt: harness.clock.now))],
            effects: [.itemPreWriteBaseline(itemID: id, updatedAt: nil)]
        ))
        #expect(try persistence.journalEntries(states: [.failed]).count == 1)

        #expect(throws: SyncError.locked) {
            try persistence.commit(SyncCommitModel(effects: [
                .itemPushed(ItemPushedEffectModel(
                    itemID: id,
                    syncedName: "FXV_LATE",
                    sourceFingerprint: fingerprint,
                    pushedFingerprint: fingerprint,
                    didNormalizeValue: false,
                    preWriteUpdatedAt: nil,
                    detachedPreviousName: nil
                )),
            ]))
        }
        #expect(try harness.record(id).syncedName == nil)
    }

    // MARK: - Values

    @Test func valuesAreDecryptedInsideTheSession() async throws {
        let harness = try await harness()
        let id = try harness.add("FXV_READ", kind: .secret, value: "readable")
        let missing = try harness.insertRow("FXV_MISSING", kind: .secret, value: nil, syncedName: "FXV_MISSING")
        let values = VaultSyncValues(session: harness.session)

        let read = try #require(try values.value(of: id))
        #expect(read.value.utf8String() == "readable")
        #expect(read.fingerprint == (try harness.record(id).valueFingerprint))
        read.wipe()
        #expect(try values.value(of: missing) == nil)
        #expect(try values.value(of: ConfigItemID()) == nil)
        let bytes = SecretBytes(utf8: "readable")
        #expect(try values.fingerprint(bytes, rowID: id) == (try harness.record(id).valueFingerprint))

        harness.manager.lock()
        #expect(throws: SyncError.locked) { try values.ensureUnlocked() }
        #expect(throws: SyncError.locked) { _ = try values.value(of: id) }
        #expect(throws: SyncError.locked) { _ = try values.fingerprint(bytes, rowID: id) }
    }
}
