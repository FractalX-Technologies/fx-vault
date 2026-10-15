import Foundation
import FXVaultTestSupport
import GitHubKit
import SyncEngine
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// ``SyncRepository`` end to end: an in-memory vault, the simulated GitHub (FakeCommandRunner
/// underneath) and SyncEngine's real preflight, planner and executor.
@Suite("SyncRepository", .timeLimit(.minutes(1)))
struct SyncRepositoryTests {
    /// GitHub has a repository secret, a repository variable and a `staging` environment; the
    /// vault imported it.
    private func importedHarness() async throws -> SyncHarness {
        let github = GitHubSimulator(owner: SyncFixture.owner, name: SyncFixture.repoName)
        github.addSecret("FXV_API_TOKEN")
        github.addVariable("FXV_API_URL", value: "https://one.example.invalid")
        github.addEnvironment("staging")
        let harness = try await SyncHarness.make(github: github)
        try await harness.importRepository()
        return harness
    }

    @Test func importedRepositoryHasNothingPending() async throws {
        let harness = try await importedHarness()
        #expect(try harness.pendingCount() == 0)
        #expect(try harness.sync.pendingSummary().repositories.isEmpty)
        #expect(try harness.sync.lastRunReport() == nil)
    }

    @Test func syncPushesEveryChangeAndVerifiesIt() async throws {
        let harness = try await importedHarness()
        let staging = try #require(try harness.environment("staging"))
        let newSecret = try harness.add("FXV_NEW_SECRET", kind: .secret, value: "fixture-secret-1")
        let stagingVariable = try harness.add("FXV_STAGE_URL", kind: .variable, value: "https://stage.example.invalid", scope: .environment(staging.id))
        let url = try #require(try harness.item("FXV_API_URL", kind: .variable))
        try harness.config.editValue(url.id, value: SecretBytes(utf8: "https://two.example.invalid"))
        let token = try #require(try harness.item("FXV_API_TOKEN", kind: .secret))
        try harness.config.deleteItem(token.id)
        #expect(try harness.pendingCount() == 4)

        let review = try await harness.sync.preflight()
        #expect(review.preflight.executableCount == 4)
        #expect(review.deletionCount == 1)
        #expect(review.credentialWarnings.isEmpty)
        let handle = try await harness.sync.startRun(review, includeDeletions: true)
        let outcome = await handle.outcome()

        #expect(outcome.result.stopReason == nil)
        #expect(outcome.result.failed.isEmpty)
        #expect(outcome.result.succeeded.count == 4)
        #expect(harness.github.secret("FXV_NEW_SECRET")?.value == "fixture-secret-1")
        #expect(harness.github.secret("FXV_API_TOKEN") == nil)
        #expect(harness.github.variable("FXV_API_URL")?.value == "https://two.example.invalid")
        #expect(harness.github.variable("FXV_STAGE_URL", environment: "staging")?.value == "https://stage.example.invalid")

        #expect(try harness.pendingCount() == 0)
        let pushed = try harness.record(newSecret)
        #expect(pushed.syncedName == "FXV_NEW_SECRET")
        #expect(pushed.verifyState == .verified)
        #expect(pushed.remoteUpdatedAt != nil)
        #expect(try harness.syncedValue(newSecret) == "fixture-secret-1")
        #expect(try harness.syncedValue(url.id) == "https://two.example.invalid")
        #expect(try harness.record(stagingVariable).verifyState == .verified)
        #expect(try harness.store.fetchItemRecord(id: token.id) == nil)

        let report = try #require(try harness.sync.lastRunReport())
        #expect(report.runID == review.preflight.runID)
        #expect(report.unresolved.isEmpty)
        #expect(report.entries(in: .succeeded).filter(\.isWrite).count == 4)
        #expect(report.entries.allSatisfy { $0.itemName.map { !$0.contains("example") } ?? true })
    }

    /// v0.3.1: a personal repository of an Enterprise Managed User (`handle_shortcode`,
    /// synthetic) imports and syncs; every gh call names it `user1_acme/api` and the token is
    /// fetched for that login.
    @Test func managedUserRepositoryImportsAndSyncs() async throws {
        let owner = "user1_acme"
        let github = GitHubSimulator(owner: owner, name: SyncFixture.repoName)
        github.addSecret("FXV_API_TOKEN")
        let harness = try await SyncHarness.make(github: github)
        let imported = try await harness.catalog.importRepository(
            try GHRepoRef(owner: owner, name: SyncFixture.repoName),
            accountLogin: owner
        ).repository
        #expect(imported.ownerLogin == owner)
        #expect(imported.accountLogin == owner)
        #expect(try harness.store.fetchItemStates(repositoryID: imported.id).map(\.name) == ["FXV_API_TOKEN"])

        try harness.config.addItem(
            repositoryID: imported.id,
            scope: .repository,
            kind: .secret,
            name: "FXV_NEW_SECRET",
            value: SecretBytes(utf8: "fixture-secret-emu")
        )
        let outcome = try await harness.runSync()
        #expect(outcome.result.stopReason == nil)
        #expect(outcome.result.failed.isEmpty)
        #expect(github.secret("FXV_NEW_SECRET")?.value == "fixture-secret-emu")
        #expect(github.writes.contains { $0.starts(with: ["secret", "set", "FXV_NEW_SECRET"]) && $0.contains("--repo=user1_acme/api") })
        #expect(github.calls.contains(["auth", "token", "--hostname", "github.com", "--user=user1_acme"]))
        #expect(try harness.sync.pendingSummary().pendingCount == 0)
    }

    @Test func declinedDeletionStaysPending() async throws {
        let harness = try await importedHarness()
        let token = try #require(try harness.item("FXV_API_TOKEN", kind: .secret))
        try harness.config.deleteItem(token.id)
        let outcome = try await harness.runSync(includeDeletions: false)
        #expect(outcome.result.skipped.count == 1)
        #expect(harness.github.secret("FXV_API_TOKEN") != nil)
        #expect(try harness.pendingCount() == 1)
    }

    @Test func partialFailureKeepsTheFailedItemPending() async throws {
        let harness = try await importedHarness()
        let secret = try harness.add("FXV_DENIED", kind: .secret, value: "fixture-secret-2")
        let variable = try harness.add("FXV_ALLOWED", kind: .variable, value: "fixture-variable")
        harness.github.enqueue(
            .failure(stderr: "failed to set secret \"FXV_DENIED\": HTTP 403: Must have admin rights to Repository. (https://api.github.com/repos/owner-a/api/actions/secrets/FXV_DENIED)"),
            matching: GHMatch.secretSet("FXV_DENIED")
        )

        let outcome = try await harness.runSync()

        #expect(outcome.result.failed.map(\.change.operation.itemID) == [secret])
        #expect(outcome.result.succeeded.map(\.change.operation.itemID) == [variable])
        #expect(try harness.record(secret).syncedName == nil)
        #expect(try harness.record(variable).syncedName == "FXV_ALLOWED")
        #expect(try harness.pendingCount() == 1)
        let report = try #require(try harness.sync.lastRunReport())
        #expect(report.entries(in: .failed).map(\.itemName) == ["FXV_DENIED"])
        #expect(report.entries(in: .failed).first?.errorCode == GHError.adminRequired.logCode)

        // The next Sync retries only what is still pending.
        let retry = try await harness.runSync()
        #expect(retry.result.succeeded.map(\.change.operation.itemID) == [secret])
        #expect(try harness.pendingCount() == 0)
    }

    @Test func launchReconciliationResolvesALeftoverInFlightWrite() async throws {
        let harness = try await importedHarness()
        let id = try harness.add("FXV_CRASHED", kind: .variable, value: "landed-value")
        // A crash right after gh wrote the variable: GitHub has it, the journal row is in flight.
        harness.github.addVariable("FXV_CRASHED", value: "landed-value")
        let repository = try harness.repository()
        let persistence = VaultSyncPersistence(session: harness.session, clock: harness.clock)
        let entryID = try persistence.appendJournal(SyncJournalEntryModel(
            runID: SyncRunID(),
            accountLogin: SyncFixture.login,
            repositoryID: repository.id,
            op: ConfigChangeKind.setVariable.rawValue,
            command: .variableSet,
            scopeLabel: SyncExecutionConstants.repositoryScopeLabel,
            targetKey: RemoteItemKeyModel(scope: .repository, kind: .variable, name: "FXV_CRASHED").journalKey,
            itemName: "FXV_CRASHED",
            startedAt: harness.clock.now
        ))

        let reconciliation = try await harness.sync.prepareAfterUnlock()

        #expect(reconciliation.reconciled.map(\.id) == [entryID])
        let row = try harness.record(id)
        #expect(row.syncedName == "FXV_CRASHED")
        #expect(row.verifyState == .verified)
        #expect(try harness.pendingCount() == 0)
        #expect(try persistence.journalEntries(states: SyncJournalOutcomeState.unresolved).isEmpty)
    }

    @Test func preflightReconcilesOncePerUnlock() async throws {
        let harness = try await importedHarness()
        try harness.add("FXV_LATER", kind: .variable, value: "later")
        let persistence = VaultSyncPersistence(session: harness.session, clock: harness.clock)
        _ = try persistence.appendJournal(SyncJournalEntryModel(
            runID: SyncRunID(),
            accountLogin: SyncFixture.login,
            repositoryID: try harness.repository().id,
            op: ConfigChangeKind.setVariable.rawValue,
            command: .variableSet,
            scopeLabel: SyncExecutionConstants.repositoryScopeLabel,
            targetKey: RemoteItemKeyModel(scope: .repository, kind: .variable, name: "FXV_LATER").journalKey,
            itemName: "FXV_LATER",
            startedAt: harness.clock.now
        ))
        _ = try await harness.sync.preflight()
        // GitHub never got it: the row is closed as failed and the change stays pending.
        #expect(try persistence.journalEntries(states: SyncJournalOutcomeState.unresolved).isEmpty)
        #expect(try persistence.journalEntries(states: [.failed]).count == 1)
        #expect(try harness.pendingCount() == 1)
    }

    @Test func credentialLookingVariablesAreFlagged() async throws {
        let harness = try await importedHarness()
        try harness.add("FXV_DB_PASSWORD", kind: .variable, value: "plain-looking-value")
        try harness.add("FXV_REGION", kind: .variable, value: "eu-central")
        let review = try await harness.sync.preflight()
        #expect(review.credentialWarnings.map(\.name) == ["FXV_DB_PASSWORD"])
        #expect(review.credentialWarnings.first?.reasons.isEmpty == false)
    }

    @Test func pendingSummaryFollowsEdits() async throws {
        let harness = try await importedHarness()
        var updates = harness.sync.observePendingSummary().makeAsyncIterator()
        #expect(try await updates.next()?.pendingCount == 0)
        try harness.add("FXV_WATCHED", kind: .secret, value: "watched")
        #expect(try await updates.next()?.pendingCount == 1)
        let summary = try harness.sync.pendingSummary()
        #expect(summary.repositories.first?.fullName == "owner-a/api")
        #expect(summary.repositories.first?.scopes.first?.items.map(\.name) == ["FXV_WATCHED"])
    }

    @Test func runIsRefusedWhileLocked() async throws {
        let harness = try await importedHarness()
        try harness.add("FXV_LOCKED", kind: .secret, value: "value")
        let review = try await harness.sync.preflight()
        harness.manager.lock()
        await #expect(throws: SyncRepositoryError.vault(.locked)) {
            _ = try await harness.sync.startRun(review, includeDeletions: true)
        }
        await #expect(throws: SyncRepositoryError.vault(.locked)) {
            _ = try await harness.sync.preflight()
        }
    }

    @Test func deletionPreviewFetchesTheEnvironmentLive() async throws {
        let harness = try await importedHarness()
        harness.github.addVariable("FXV_REMOTE_ONLY", value: "gone", environment: "staging")
        let staging = try #require(try harness.environment("staging"))
        try harness.config.deleteEnvironment(staging.id)
        let review = try await harness.sync.preflight()
        let previews = await harness.sync.deletionPreview(for: review)
        let environment = try #require(previews.first?.environments.first)
        #expect(environment.name == "staging")
        guard case .loaded(let contents) = environment.contents else {
            Issue.record("Expected loaded contents, got \(environment.contents)")
            return
        }
        #expect(contents.remoteOnly.map(\.name) == ["FXV_REMOTE_ONLY"])
    }
}
