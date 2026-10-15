import Foundation
import FXVaultTestSupport
import GitHubKit
@testable import SyncEngine
import Testing
import VaultCore

@Suite("SyncReconciler (launch)")
struct ReconcilerTests {
    @discardableResult
    private func leftover(
        _ world: ExecWorld,
        command: SyncJournalCommand,
        op: ConfigChangeKind,
        target: String,
        state: SyncJournalOutcomeState = .inFlight,
        preWrite: Date? = nil,
        errorCode: String? = nil
    ) -> SyncJournalEntryID {
        world.vault.seedJournal(SyncJournalEntryModel(
            runID: SyncRunID(),
            accountLogin: ExecScenario.account,
            repositoryID: world.repositoryID,
            op: op.rawValue,
            command: command,
            scopeLabel: SyncExecutionConstants.repositoryScopeLabel,
            targetKey: target,
            state: state,
            errorCode: errorCode,
            startedAt: world.clock.now,
            preWriteUpdatedAt: preWrite
        ))
    }

    private func item(_ kind: ConfigKind, _ name: String, environment: String? = nil) -> String {
        RemoteItemKeyModel(scope: environment.map(RemoteScopeKeyModel.environment(named:)) ?? .repository, kind: kind, name: name).journalKey
    }

    @Test func anInFlightSecretSetThatLandedIsReconciled() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let id = scenario.newItem("FXV_TOKEN", kind: .secret, value: "v")
        let world = ExecWorld(scenario, github: github)
        let entry = leftover(world, command: .secretSet, op: .setSecret, target: item(.secret, "FXV_TOKEN"))
        let landed = github.addSecret("FXV_TOKEN")

        let outcome = try await world.reconciler().reconcile(world.vault.snapshots)

        #expect(outcome.reconciled.map(\.id) == [entry])
        #expect(world.vault.journal.first?.state == .reconciled)
        let row = try #require(world.vault.item(id))
        #expect(row.isSynced && row.verifyState == .verified && row.remoteUpdatedAt == landed)
        #expect(ChangeSetBuilder.build(world.snapshot).isEmpty)
    }

    @Test func anIndeterminateSecretSetWhoseUpdatedAtDidNotMoveFails() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let id = scenario.syncedItem("FXV_TOKEN", kind: .secret, value: "new", syncedValue: "old", github: github)
        let world = ExecWorld(scenario, github: github)
        let before = github.secret("FXV_TOKEN")?.updatedAt
        leftover(world, command: .secretSet, op: .setSecret, target: item(.secret, "FXV_TOKEN"), state: .indeterminate, preWrite: before, errorCode: "indeterminate")

        let outcome = try await world.reconciler().reconcile(world.vault.snapshots)

        #expect(outcome.failed.count == 1)
        #expect(world.vault.journal.first?.state == .failed && world.vault.journal.first?.errorCode == "indeterminate")
        #expect(world.vault.item(id)?.hasPendingChange == true)
    }

    @Test func variablesReconcileByTheFingerprintOfTheNormalizedLocalValue() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let landed = scenario.newItem("FXV_LANDED", kind: .variable, value: "value\n")
        let lost = scenario.newItem("FXV_LOST", kind: .variable, value: "mine")
        let world = ExecWorld(scenario, github: github)
        leftover(world, command: .variableSet, op: .setVariable, target: item(.variable, "FXV_LANDED"))
        leftover(world, command: .variableSet, op: .setVariable, target: item(.variable, "FXV_LOST"))
        github.addVariable("FXV_LANDED", value: "value")
        github.addVariable("FXV_LOST", value: "theirs")

        let outcome = try await world.reconciler().reconcile(world.vault.snapshots)

        #expect(outcome.reconciled.count == 1 && outcome.failed.count == 1)
        #expect(world.vault.item(landed)?.verifyState == .verified)
        #expect(world.vault.storedValue(of: landed) == "value")
        #expect(world.vault.item(lost)?.isSynced == false)
    }

    @Test func anInFlightDeleteOfAGoneNameRemovesTheTombstone() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let id = scenario.syncedItem("FXV_OLD", kind: .secret, value: "v", syncedValue: "v", github: github, isDeleted: true)
        let world = ExecWorld(scenario, github: github)
        leftover(world, command: .secretDelete, op: .deleteSecret, target: item(.secret, "FXV_OLD"))
        github.removeSecret("FXV_OLD")

        let outcome = try await world.reconciler().reconcile(world.vault.snapshots)

        #expect(outcome.reconciled.count == 1)
        #expect(world.vault.item(id) == nil)
    }

    @Test func anInFlightEnvironmentPutIsRecordedWhenB4ShowsIt() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let staging = scenario.newEnvironment("staging", policy: .protectedBranches)
        let world = ExecWorld(scenario, github: github)
        leftover(world, command: .environmentPut, op: .upsertEnvironment, target: RemoteScopeKeyModel.environment(named: "staging").journalKey)
        let githubID = github.addEnvironment("staging", policy: .protected)

        let outcome = try await world.reconciler().reconcile(world.vault.snapshots)

        #expect(outcome.reconciled.count == 1)
        let environment = try #require(world.vault.environment(staging.id))
        #expect(environment.syncedName == "staging" && environment.githubEnvID == githubID && environment.syncedBranchPolicy == .protected)
    }

    @Test func anInFlightCreateIsAdoptedOnlyAfterAJournaledFreeLookup() async throws {
        let github = GitHubSimulator(exists: true)
        let scenario = ExecScenario(onGitHub: false)
        let world = ExecWorld(scenario, github: github)
        leftover(world, command: .repoView, op: .createRepository, target: "repo", state: .failed, errorCode: GHError.notFound.logCode)
        leftover(world, command: .repoCreate, op: .createRepository, target: "repo")

        let outcome = try await world.reconciler().reconcile(world.vault.snapshots)

        #expect(outcome.reconciled.count == 1)
        #expect(world.snapshot.repository.githubID == "R_simulated")
    }

    @Test func aCreateWithoutTheFreeLookupOrWithAnotherVisibilityIsAConflict() async throws {
        let github = GitHubSimulator(exists: true, visibility: .public)
        let scenario = ExecScenario(onGitHub: false)
        let world = ExecWorld(scenario, github: github)
        leftover(world, command: .repoView, op: .createRepository, target: "repo", state: .failed, errorCode: GHError.notFound.logCode)
        leftover(world, command: .repoCreate, op: .createRepository, target: "repo")

        let outcome = try await world.reconciler().reconcile(world.vault.snapshots)

        #expect(outcome.conflicts.count == 1)
        #expect(world.vault.journal.last?.errorCode == SyncExecutionConstants.createConflictErrorCode)
        #expect(world.snapshot.repository.githubID == nil)
    }

    @Test func patternWritesAreClosedAndUnknownRepositoriesLeftForLater() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let world = ExecWorld(scenario, github: github)
        leftover(world, command: .branchPolicyAdd, op: .reconcileBranchPatterns, target: RemoteScopeKeyModel.environment(named: "x").journalKey)
        world.vault.seedJournal(SyncJournalEntryModel(
            runID: SyncRunID(),
            accountLogin: ExecScenario.account,
            repositoryID: RepoID(),
            op: ConfigChangeKind.setSecret.rawValue,
            command: .secretSet,
            scopeLabel: SyncExecutionConstants.repositoryScopeLabel,
            targetKey: item(.secret, "FXV_OTHER"),
            startedAt: world.clock.now
        ))

        let outcome = try await world.reconciler().reconcile(world.vault.snapshots)

        #expect(outcome.failed.count == 1 && outcome.unchecked.count == 1)
        #expect(world.vault.journal.last?.state == .inFlight)
    }
}

@Suite("WriteVerifier")
struct WriteVerifierTests {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func secretRule() {
        let listed = RemoteSecretModel(name: "A", updatedAt: base.addingTimeInterval(1))
        #expect(WriteVerifier.isSecretVerified(listed: listed, preWriteUpdatedAt: base))
        #expect(WriteVerifier.isSecretVerified(listed: listed, preWriteUpdatedAt: nil))
        #expect(!WriteVerifier.isSecretVerified(listed: listed, preWriteUpdatedAt: base.addingTimeInterval(1.0004)))
        #expect(!WriteVerifier.isSecretVerified(listed: nil, preWriteUpdatedAt: nil))
    }

    private func pendingSnapshot() -> (RepoSnapshotModel, ConfigItemID, ConfigItemID) {
        let scenario = ExecScenario()
        let secret = scenario.newItem("FXV_SECRET", kind: .secret, value: "s")
        let variable = scenario.newItem("FXV_VARIABLE", kind: .variable, value: "v")
        for index in scenario.items.indices {
            scenario.items[index].syncedName = scenario.items[index].name
            scenario.items[index].syncedFingerprint = scenario.items[index].valueFingerprint
            scenario.items[index].verifyState = .pending
            scenario.items[index].preWriteUpdatedAt = base
        }
        return (scenario.snapshot, secret, variable)
    }

    private func remote(secretAt date: Date, variable: Data?, variableRow: ConfigItemID) -> RemoteSnapshotModel {
        RemoteSnapshotModel(
            repository: RemoteScopeListingModel(
                secrets: [RemoteSecretModel(name: "FXV_SECRET", updatedAt: date)],
                variables: [RemoteVariableModel(name: "FXV_VARIABLE", updatedAt: date, fingerprints: variable.map { [variableRow: $0] } ?? [:])]
            ),
            environments: []
        )
    }

    @Test func pendingRowsVerifyWhenTheRelistMatches() {
        let (snapshot, secret, variable) = pendingSnapshot()
        let changed = base.addingTimeInterval(5)
        let pass = WriteVerifier.pendingVerificationPass(
            local: snapshot,
            remote: remote(secretAt: changed, variable: InMemorySyncVault.fingerprint("v", rowID: variable), variableRow: variable)
        )
        #expect(Set(pass.verified) == [secret, variable])
        #expect(pass.effects.contains(.itemVerified(itemID: secret, remoteUpdatedAt: changed)))
        #expect(pass.snapshot.items.allSatisfy { $0.verifyState == .verified })
        #expect(pass.failedChecks.isEmpty)
    }

    @Test func pendingRowsExpireAfterTheConfiguredChecks() {
        let (snapshot, secret, variable) = pendingSnapshot()
        let unchanged = remote(secretAt: base, variable: Data("other".utf8), variableRow: variable)
        var checks: [ConfigItemID: Int] = [:]
        var current = snapshot
        for pass in 1..<Limits.pendingVerifyChecks {
            let result = WriteVerifier.pendingVerificationPass(local: current, remote: unchanged, failedChecks: checks)
            #expect(result.effects.isEmpty)
            #expect(result.failedChecks[secret] == pass)
            checks = result.failedChecks
            current = result.snapshot
        }
        let last = WriteVerifier.pendingVerificationPass(local: current, remote: unchanged, failedChecks: checks)
        #expect(Set(last.expired) == [secret, variable])
        #expect(last.effects.contains(.itemVerificationExpired(itemID: secret, forcePush: true)))
        #expect(last.effects.contains(.itemVerificationExpired(itemID: variable, forcePush: false)))
        #expect(last.snapshot.items.first { $0.id == secret }?.forcePush == true)
        #expect(ChangeSetBuilder.build(last.snapshot).changes.map(\.kind) == [.setSecret])
    }

    @Test func preflightPassesDoNotCountMissesAndUnlistedScopesAreSkipped() {
        let (snapshot, _, variable) = pendingSnapshot()
        let unchanged = remote(secretAt: base, variable: nil, variableRow: variable)
        let preflight = WriteVerifier.pendingVerificationPass(local: snapshot, remote: unchanged, countsMisses: false)
        #expect(preflight.effects.isEmpty && preflight.failedChecks.isEmpty)
        let unlisted = WriteVerifier.pendingVerificationPass(local: snapshot, remote: RemoteSnapshotModel(repository: nil, environments: []))
        #expect(unlisted.failedChecks.isEmpty && unlisted.effects.isEmpty)
    }
}

@Suite("DeletionPreviewLoader")
struct DeletionPreviewTests {
    @Test func listsLocalAndRemoteNamesWithRemoteOnlyOnesMarked() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let qa = scenario.syncedEnvironment("qa", github: github, id: 30, policy: .custom([
            BranchPatternModel(environmentID: EnvironmentID(), pattern: "release/*", type: .branch),
        ]))
        scenario.syncedItem("FXV_KNOWN", kind: .secret, value: "k", syncedValue: "k", in: qa, github: github)
        scenario.environments[0].isDeleted = true
        github.addVariable("FXV_TEAMMATE", value: "t", environment: "qa")
        scenario.syncedItem("FXV_GONE", kind: .variable, value: "g", syncedValue: "g", github: github, isDeleted: true)
        let world = ExecWorld(scenario, github: github)
        let preflight = try await world.preflight()

        let previews = await DeletionPreviewLoader(schedulers: world.registry).load(preflight)

        let preview = try #require(previews.first)
        #expect(preview.deletionCount == 2 && preview.itemDeletions.map(\.kind) == [.deleteVariable])
        guard case .loaded(let contents) = preview.environments.first?.contents else {
            Issue.record("contents must load")
            return
        }
        #expect(contents.policy == .custom && contents.patterns == ["release/*"])
        #expect(contents.items.map(\.name) == ["FXV_TEAMMATE", "FXV_KNOWN"])
        #expect(contents.remoteOnly.map(\.name) == ["FXV_TEAMMATE"])
        #expect(contents.items.first { $0.name == "FXV_KNOWN" }?.isOnGitHub == true)
        #expect(!preview.hasUnknownContents)
    }

    @Test func aFailedFetchIsContentsUnknownAndAMissingEnvironmentIsAlreadyDeleted() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.syncedEnvironment("qa", github: github, id: 30)
        scenario.syncedEnvironment("old", github: github, id: 31)
        scenario.environments[0].isDeleted = true
        scenario.environments[1].isDeleted = true
        let world = ExecWorld(scenario, github: github)
        let preflight = try await world.preflight()
        github.removeEnvironment("old")
        for _ in 0...Limits.idempotentRetries {
            github.enqueue(.failure(stderr: "failed to get secrets: HTTP 502: Bad Gateway"), matching: GHMatch.all(GHMatch.secretList, GHMatch.environment("qa")))
        }

        let preview = try #require(await DeletionPreviewLoader(schedulers: world.registry).load(preflight).first)

        let states = Dictionary(uniqueKeysWithValues: preview.environments.map { ($0.name, $0.contents) })
        #expect(states["old"] == .alreadyDeleted)
        #expect(states["qa"] == .unknown(.serverError(status: 502)))
        #expect(preview.hasUnknownContents)
    }
}

@Suite("InMemorySyncVault effects")
struct InMemorySyncVaultTests {
    @Test func aPushRecordsTheSyncedValueOnlyWhenTheValueWasNotEditedMeanwhile() throws {
        let scenario = ExecScenario()
        let kept = scenario.newItem("FXV_KEPT", kind: .variable, value: "a\n")
        let edited = scenario.newItem("FXV_EDITED", kind: .variable, value: "b")
        let vault = InMemorySyncVault(snapshots: [scenario.snapshot], values: scenario.values.compactMapValues { $0 })
        vault.setValue("edited", for: edited)

        try vault.commit(SyncCommitModel(effects: [
            .itemPushed(ItemPushedEffectModel(
                itemID: kept,
                syncedName: "FXV_KEPT",
                sourceFingerprint: InMemorySyncVault.fingerprint("a\n", rowID: kept),
                pushedFingerprint: InMemorySyncVault.fingerprint("a", rowID: kept),
                didNormalizeValue: true,
                preWriteUpdatedAt: nil,
                detachedPreviousName: nil
            )),
            .itemPushed(ItemPushedEffectModel(
                itemID: edited,
                syncedName: "FXV_EDITED",
                sourceFingerprint: InMemorySyncVault.fingerprint("b", rowID: edited),
                pushedFingerprint: InMemorySyncVault.fingerprint("b", rowID: edited),
                didNormalizeValue: false,
                preWriteUpdatedAt: nil,
                detachedPreviousName: nil
            )),
        ]))

        #expect(vault.storedValue(of: kept) == "a" && vault.storedSyncedValue(of: kept) == "a")
        #expect(vault.item(kept)?.hasPendingChange == false)
        #expect(vault.storedValue(of: edited) == "edited" && vault.storedSyncedValue(of: edited) == nil)
        #expect(vault.item(edited)?.hasSyncedValue == false && vault.item(edited)?.hasPendingChange == true)
    }

    @Test func failingCommitsAndALockedVaultThrow() throws {
        let scenario = ExecScenario()
        let id = scenario.newItem("FXV_TOKEN", kind: .secret, value: "v")
        let vault = InMemorySyncVault(snapshots: [scenario.snapshot], values: scenario.values.compactMapValues { $0 })
        vault.failCommits(after: 0)
        #expect(throws: SyncError.persistenceFailed) { try vault.commit(SyncCommitModel()) }
        vault.lock()
        #expect(throws: SyncError.locked) { try vault.value(of: id) }
        vault.unlock()
        #expect(try vault.value(of: id)?.fingerprint == InMemorySyncVault.fingerprint("v", rowID: id))
    }
}
