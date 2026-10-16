import Foundation
import GitHubKit
import SyncEngine
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// The Sync sheet with shared scopes (v0.6.0, S5, Q3): one issue per blocked shared scope with
/// its fix, Get Updates from Teammates, the takeover confirmation, and "What changed?".
@MainActor
@Suite("Sync sheet with shared scopes")
struct SyncSpaceSheetTests {
    static let space = SpaceID()

    static func fixture(_ decision: SpaceGateDecision, executable: [ConfigChangeModel] = []) async throws -> SyncViewModelTests.Fixture {
        let blocked = [
            SyncFixtures.set(.secret, "API_TOKEN"),
            SyncFixtures.set(.variable, "BASE_URL"),
        ].map { SyncBlockedChangeModel(change: $0, reason: .space(SyncSpaceBlockModel(spaceID: space, decision: decision))) }
        let gate = SyncSpaceGateModel(spaceID: space, scope: .repository, decision: decision, hasMarker: true)
        let review = SyncFixtures.review([SyncFixtures.preflight(executable: executable, blocked: blocked, spaces: [gate])])
        return try await SyncViewModelTests.Fixture(review: .success(review))
    }

    @Test func aBehindScopeIsOneIssueThatGetsTheTeammatesVersions() async throws {
        let fixture = try await Self.fixture(.behind(version: 9, login: "user-b"))
        let model = fixture.viewModel
        await model.load()

        let repository = try #require(model.repositories.first)
        #expect(repository.blocked.count == 1)
        let issue = try #require(repository.blocked.first)
        #expect(issue.title == "Shared with teammates · Repository")
        #expect(issue.reason.contains("user-b published v9"))
        #expect(issue.reason.contains("2 changes wait for it."))
        #expect(issue.fix == .getTeammateUpdates)

        model.perform(.getTeammateUpdates)
        #expect(await TestFixtures.eventually { fixture.recorder.spaceSyncs == 1 && fixture.service.preflightCalls.count == 2 })
        #expect(!model.isGettingTeammateUpdates)
    }

    @Test func aStalePushIsTakenOverOnlyAfterTheConfirmation() async throws {
        let since = Date(timeIntervalSince1970: 1_790_000_000)
        let fixture = try await Self.fixture(.publishing(login: "user-b", since: since, isStale: true))
        let model = fixture.viewModel
        await model.load()

        let issue = try #require(model.repositories.first?.blocked.first)
        #expect(issue.fix == .takeOverSpace(Self.space, login: "user-b"))
        model.perform(.takeOverSpace(Self.space, login: "user-b"))
        #expect(model.pendingTakeover?.login == "user-b")
        #expect(fixture.service.takeoverCalls == [[]])

        await model.confirmTakeover()
        #expect(model.pendingTakeover == nil)
        #expect(fixture.service.takeoverCalls == [[], [Self.space]])
    }

    @Test func aPushInAFreshPublishIsNotTakenOver() async throws {
        let fixture = try await Self.fixture(.publishing(login: "user-b", since: Date(timeIntervalSince1970: 0), isStale: false))
        let model = fixture.viewModel
        await model.load()
        #expect(model.repositories.first?.blocked.first?.fix == nil)
    }

    @Test func whatChangedGoesIntoTheRunAndMembersAreTold() async throws {
        let change = SyncFixtures.set(.secret, "API_TOKEN")
        let gate = SyncSpaceGateModel(spaceID: Self.space, scope: .repository, decision: .clear, hasMarker: true)
        let review = SyncFixtures.review([SyncFixtures.preflight(executable: [change], spaces: [gate])])
        let fixture = try await SyncViewModelTests.Fixture(review: .success(review))
        let model = fixture.viewModel
        await model.load()
        #expect(model.publishesSharedVersions)
        #expect(model.repositories.first?.notes == [SyncCopy.spacePublishNote])
        model.spaceReason = "  Rotate the token  "

        let task = await fixture.startRun()
        fixture.service.run.finish(SyncFixtures.outcome([SyncChangeResultModel(change: change, outcome: .succeeded(.verified))]))
        await task.value

        #expect(fixture.service.startedRuns.first?.spaceReason == "Rotate the token")
        #expect(fixture.recorder.spacePublishes == 1)
    }
}
