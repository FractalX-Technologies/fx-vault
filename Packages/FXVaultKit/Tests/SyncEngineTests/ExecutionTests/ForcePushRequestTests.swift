import Foundation
import FXVaultTestSupport
import GitHubKit
@testable import SyncEngine
import Testing
import VaultCore

/// v0.1.2: a push the user requested (Fill without "Already matches GitHub", Push on Next Sync)
/// against the D27 remote-changed rule. The request covers GitHub changes made before it; a
/// change after it still blocks; pushes FX Vault scheduled itself keep the strict rule.
@Suite("Requested pushes and D27")
struct ForcePushRequestTests {
    /// One synced secret whose local value equals the synced one, changed on GitHub
    /// `changedAfter` seconds after the vault last saw it, with a push requested
    /// `requestedAfter` seconds after that same base (nil: a push FX Vault scheduled itself).
    private static func scenario(
        changedAfter: TimeInterval,
        requestedAfter: TimeInterval?
    ) throws -> (world: ExecWorld, github: GitHubSimulator, id: ConfigItemID) {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let id = scenario.syncedItem("FXV_TOKEN", kind: .secret, value: "v", syncedValue: "v", github: github, forcePush: true)
        let base = try #require(scenario.items[0].remoteUpdatedAt)
        _ = github.addSecret("FXV_TOKEN", updatedAt: base.addingTimeInterval(changedAfter))
        scenario.items[0].forcePushRequestedAt = requestedAfter.map { base.addingTimeInterval($0) }
        return (ExecWorld(scenario, github: github), github, id)
    }

    @Test func aRequestedPushReplacesAGitHubChangeMadeBeforeTheRequest() async throws {
        let (world, github, id) = try Self.scenario(changedAfter: 60, requestedAfter: 120)

        let preflight = try await world.preflight()
        #expect(preflight.repositories[0].remoteChanged.isEmpty)
        #expect(preflight.repositories[0].executable.map(\.kind) == [.setSecret])

        let result = try await world.executor().run(SyncPlanner.plan(preflight))
        #expect(result.blocked.isEmpty && result.failed.isEmpty)
        #expect(github.calls.filter(GHMatch.secretSet("FXV_TOKEN")).count == 1)
        let row = try #require(world.vault.item(id))
        #expect(!row.forcePush && row.forcePushRequestedAt == nil)
    }

    @Test func aGitHubChangeAfterTheRequestStillBlocks() async throws {
        let (world, github, _) = try Self.scenario(changedAfter: 120, requestedAfter: 60)

        let preflight = try await world.preflight()

        #expect(preflight.repositories[0].executable.isEmpty)
        #expect(preflight.repositories[0].remoteChanged.map(\.change.kind) == [.setSecret])
        #expect(github.calls.filter(GHMatch.secretSet()).isEmpty)
    }

    @Test func aPushFXVaultScheduledItselfKeepsTheStrictRule() async throws {
        let (world, _, _) = try Self.scenario(changedAfter: 60, requestedAfter: nil)

        let preflight = try await world.preflight()

        #expect(preflight.repositories[0].remoteChanged.map(\.change.kind) == [.setSecret])
    }

    @Test func theExecutorRecheckAppliesTheSameRule() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.syncedItem("FXV_TOKEN", kind: .secret, value: "v", syncedValue: "v", github: github, forcePush: true)
        let base = try #require(scenario.items[0].remoteUpdatedAt)
        scenario.items[0].forcePushRequestedAt = base.addingTimeInterval(60)
        let world = ExecWorld(scenario, github: github)
        let preflight = try await world.preflight()
        #expect(preflight.repositories[0].executable.count == 1)

        // GitHub changes after the request, between preflight and the write.
        _ = github.addSecret("FXV_TOKEN", updatedAt: base.addingTimeInterval(120))
        let result = try await world.executor().run(SyncPlanner.plan(preflight))

        #expect(result.outcome(of: .setSecret) == .blocked(.change(.remoteChanged)))
        #expect(github.calls.filter(GHMatch.secretSet()).isEmpty)
    }

    @Test func anExpiredVerificationDoesNotBringBackTheChangeTheRequestReplaced() async throws {
        let (world, github, id) = try Self.scenario(changedAfter: 60, requestedAfter: 120)
        let base = try #require(world.vault.item(id)?.remoteUpdatedAt)
        let replaced = base.addingTimeInterval(60)
        // The write does not move GitHub's updatedAt (same second, or it never landed).
        github.configure { $0.secretSetKeepsUpdatedAt = true }
        _ = try await world.sync()
        let pushed = try #require(world.vault.item(id))
        #expect(pushed.verifyState == .pending && pushed.preWriteUpdatedAt == replaced)
        let unchanged = RemoteSnapshotModel(
            repository: RemoteScopeListingModel(secrets: [RemoteSecretModel(name: "FXV_TOKEN", updatedAt: replaced)], variables: []),
            environments: []
        )
        var checks: [ConfigItemID: Int] = [:]
        var expired = false
        for _ in 0..<Limits.pendingVerifyChecks where !expired {
            let pass = WriteVerifier.pendingVerificationPass(local: world.snapshot, remote: unchanged, failedChecks: checks)
            try world.vault.commit(SyncCommitModel(effects: pass.effects))
            checks = pass.failedChecks
            expired = pass.expired == [id]
            let listed = RemoteFx.scope(secrets: [RemoteFx.secret("FXV_TOKEN", updatedAt: replaced)])
            #expect(RemoteFx.detect(pass.snapshot, repository: listed).isEmpty)
        }
        #expect(expired)
        let row = try #require(world.vault.item(id))
        #expect(row.forcePush && row.forcePushRequestedAt == nil && row.remoteUpdatedAt == replaced)

        let preflight = try await world.preflight()
        #expect(preflight.repositories[0].remoteChanged.isEmpty)
        #expect(preflight.repositories[0].executable.map(\.kind) == [.setSecret])
    }

    // MARK: - Drift detection agrees

    @Test func driftIgnoresGitHubChangesTheRequestCovers() throws {
        var row = Fx.syncedItem("API_TOKEN", remoteUpdatedAt: RemoteFx.monday)
        row.forcePush = true
        row.forcePushRequestedAt = RemoteFx.tuesday.addingTimeInterval(60)
        let covered = RemoteFx.scope(secrets: [RemoteFx.secret("API_TOKEN", updatedAt: RemoteFx.tuesday)])
        #expect(RemoteFx.detect(Fx.snapshot(items: [row]), repository: covered).isEmpty)

        row.forcePushRequestedAt = RemoteFx.monday.addingTimeInterval(1)
        let drifts = RemoteFx.detect(Fx.snapshot(items: [row]), repository: covered)
        #expect(drifts.count == 1)
        let later = try #require(drifts.first)
        #expect(later.kind == .secretModified && later.isConflict)
    }

    /// GitHub lists whole seconds and the clocks may disagree: an unclear order blocks.
    @Test func aChangeWhoseOrderIsUnclearStillBlocks() {
        var row = Fx.syncedItem("API_TOKEN", remoteUpdatedAt: RemoteFx.monday)
        row.forcePush = true
        let listedSecond = Date(timeIntervalSince1970: RemoteFx.tuesday.timeIntervalSince1970.rounded(.down))
        let margin = SyncEngineConstants.requestedPushClockMargin

        // A rotation at .900 listed as .000, after a request at .700 in the same second.
        row.forcePushRequestedAt = listedSecond.addingTimeInterval(0.7)
        #expect(row.isSecretChangedOnGitHub(updatedAt: listedSecond))
        // GitHub's clock behind the Mac's by less than the margin.
        row.forcePushRequestedAt = listedSecond.addingTimeInterval(margin)
        #expect(row.isSecretChangedOnGitHub(updatedAt: listedSecond))
        // Clearly before the request.
        row.forcePushRequestedAt = listedSecond.addingTimeInterval(margin + 1)
        #expect(!row.isSecretChangedOnGitHub(updatedAt: listedSecond))
    }

    @Test func aStaleRequestTimeWithoutForcePushIsIgnored() throws {
        var row = Fx.syncedItem("API_TOKEN", remoteUpdatedAt: RemoteFx.monday)
        row.forcePushRequestedAt = RemoteFx.tuesday.addingTimeInterval(1)
        #expect(row.isSecretChangedOnGitHub(updatedAt: RemoteFx.tuesday))
        #expect(!row.isSecretChangedOnGitHub(updatedAt: RemoteFx.monday))
    }
}
