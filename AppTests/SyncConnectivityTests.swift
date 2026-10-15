import Foundation
import GitHubKit
import SyncEngine
import Testing
import VaultData
@testable import FXVault

/// v0.2.0 integration of the Sync sheet and the drift review with the connectivity banner: both
/// report their gh outcomes to `GitHubReachability`, and a Sync sheet that is open when the Mac
/// goes offline cannot start a run.
@MainActor
@Suite("Sync and drift review with connectivity")
struct SyncConnectivityTests {
    private static func fixture(
        _ review: Result<SyncReviewModel, SyncRepositoryError>
    ) async throws -> SyncViewModelTests.Fixture {
        try await SyncViewModelTests.Fixture(review: review)
    }

    private static var oneChange: SyncReviewModel {
        SyncFixtures.review([SyncFixtures.preflight(executable: [SyncFixtures.set(.variable, "BASE_URL")])])
    }

    @Test func goingOfflineDisablesTheRunAndExplainsWhy() async throws {
        let fixture = try await Self.fixture(.success(Self.oneChange))
        let model = fixture.viewModel
        await model.load()
        #expect(model.canProceed)
        #expect(model.footerNotice == nil)

        fixture.harness.pathSource.send(.offline)

        #expect(!model.isOnline)
        #expect(!model.canProceed)
        #expect(model.buttons.last?.isEnabled == false)
        #expect(model.footerNotice == ConnectivityCopy.offlineHelp)
        await model.startSync(includeDeletions: false)
        #expect(fixture.service.startedRuns.isEmpty)
        #expect(model.step == .summary)
    }

    @Test func aPreflightThatCannotReachGitHubShowsTheBanner() async throws {
        let fixture = try await Self.fixture(.failure(.sync(.github(.network))))
        let reachability = fixture.harness.container.gitHubReachability
        await fixture.viewModel.load()

        #expect(!reachability.isResponding)
    }

    @Test func aSuccessfulPreflightClearsTheBanner() async throws {
        let fixture = try await Self.fixture(.success(Self.oneChange))
        let reachability = fixture.harness.container.gitHubReachability
        reachability.record(GHError.timeout)
        #expect(!reachability.isResponding)

        await fixture.viewModel.load()

        #expect(reachability.isResponding)
    }

    @Test(arguments: [
        (GHError.network, false),
        (GHError.timeout, false),
        (GHError.notFound, true),
        (GHError.serverError(status: 502), true),
    ])
    func theLastRunOutcomeDecides(error: GHError, responding: Bool) async throws {
        let change = SyncFixtures.set(.variable, "BASE_URL")
        let other = SyncFixtures.set(.secret, "API_TOKEN")
        let fixture = try await Self.fixture(.success(
            SyncFixtures.review([SyncFixtures.preflight(executable: [change, other])])
        ))
        let model = fixture.viewModel
        await model.load()
        let reachability = fixture.harness.container.gitHubReachability

        let run = await fixture.startRun()
        fixture.service.run.finish(SyncFixtures.outcome([
            SyncChangeResultModel(change: change, outcome: .succeeded(.notApplicable)),
            SyncChangeResultModel(change: other, outcome: .failed(.github(error))),
        ]))
        await run.value

        #expect(model.step == .result)
        #expect(reachability.isResponding == responding)
    }

    @Test func aRunWithoutGitHubSignalsChangesNothing() async throws {
        let change = SyncFixtures.set(.variable, "BASE_URL")
        let fixture = try await Self.fixture(.success(Self.oneChange))
        let model = fixture.viewModel
        await model.load()
        let reachability = fixture.harness.container.gitHubReachability
        reachability.record(GHError.network)

        let run = await fixture.startRun()
        fixture.service.run.finish(SyncFixtures.outcome([
            SyncChangeResultModel(change: change, outcome: .failed(.valueMissing)),
        ]))
        await run.value

        #expect(!reachability.isResponding)
    }

    // MARK: - Drift review

    @Test func aDriftRefreshThatCannotReachGitHubShowsTheBanner() async throws {
        let fixture = try await DriftReviewViewModelTests.Fixture(cached: nil, refresh: .failure(.github(.timeout)))
        let reachability = fixture.harness.container.gitHubReachability
        await fixture.viewModel.load()

        #expect(fixture.service.refreshCount == 1)
        #expect(!reachability.isResponding)
    }

    @Test func offlineTheDriftReviewShowsTheCachedReportButCannotRefreshOrResolve() async throws {
        let drift = DriftFixtures.item(.variableModified, .variable, "BASE_URL")
        let fixture = try await DriftReviewViewModelTests.Fixture(cached: DriftFixtures.report([drift]))
        let model = fixture.viewModel
        await model.load()
        fixture.harness.pathSource.send(.offline)

        #expect(!model.isOnline)
        #expect(model.rows.count == 1)
        #expect(model.rows.first?.keepLocal.unavailableReason == ConnectivityCopy.offlineHelp)
        #expect(model.rows.first?.acceptGitHub.isAvailable == false)
        await model.refresh()
        await model.choose(drift.id, .keepLocal)
        #expect(fixture.service.refreshCount == 0)
        #expect(fixture.service.resolutions.isEmpty)
        #expect(model.alert == nil)
        // Nothing failed against GitHub, so the reachability state is untouched.
        #expect(fixture.harness.container.gitHubReachability.isResponding)

        fixture.harness.pathSource.send(.online)
        await fixture.harness.networkClock.waitForSleepers(count: 1)
        fixture.harness.networkClock.advance(by: Theme.Durations.connectivityDebounce)
        await fixture.harness.container.connectivity.settleTask?.value
        #expect(model.isOnline)
        #expect(model.rows.first?.keepLocal.isAvailable == true)
    }

    @Test func aDriftRefreshThatSucceedsClearsTheBanner() async throws {
        let fixture = try await DriftReviewViewModelTests.Fixture(cached: nil)
        let reachability = fixture.harness.container.gitHubReachability
        reachability.record(GHError.network)

        await fixture.viewModel.refresh()

        #expect(reachability.isResponding)
    }
}
