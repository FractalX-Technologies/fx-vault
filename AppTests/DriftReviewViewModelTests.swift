import Foundation
import GitHubKit
import SyncEngine
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// The drift review and banner: alert copy, Keep Local / Accept GitHub, the fill-value
/// follow-up through the router, confirmations for local deletions, stale resolutions.
@MainActor
@Suite("Drift review")
struct DriftReviewViewModelTests {
    @MainActor
    struct Fixture {
        let harness: TestHarness
        let recorder = ActionRecorder()
        let service: FakeDriftService
        let viewModel: DriftReviewViewModel

        init(
            cached: DriftReportModel?,
            refresh: Result<DriftReportModel, DriftRepositoryError> = .success(DriftFixtures.report([])),
            isGitHubReady: Bool = true
        ) async throws {
            harness = try await TestHarness(vault: .unlocked)
            service = FakeDriftService(cached: cached, refresh: refresh)
            viewModel = DriftReviewViewModel(
                context: DriftReviewContext(repositoryID: DriftFixtures.repositoryID),
                dependencies: harness.dependencies(recorder: recorder, isGitHubReady: isGitHubReady),
                service: service
            )
        }
    }

    @Test func cachedReportShowsTheAlertCopy() async throws {
        let date = try #require(DriftFixtures.october12(year: 2026))
        let fixture = try await Fixture(cached: DriftFixtures.report([
            DriftFixtures.item(.secretModified, .secret, "API_TOKEN", updatedAt: date),
            DriftFixtures.item(.variableModified, .variable, "BASE_URL", environment: "production"),
            DriftFixtures.item(.remoteAdded, .secret, "NEW_KEY", itemID: nil, updatedAt: date),
            DriftFixtures.item(.remoteDeleted, .variable, "GONE"),
            DriftFixtures.environment(.environmentAdded, "qa", itemNames: ["QA_URL"]),
            DriftFixtures.environment(.environmentDeleted, "old"),
            DriftFixtures.environment(.environmentPolicyModified, "production"),
        ]))
        fixture.harness.clock.setWallClock(to: date)
        let model = fixture.viewModel
        await model.load()

        #expect(fixture.service.refreshCount == 0)
        let day = date.formatted(.dateTime.month(.abbreviated).day())
        #expect(model.rows.map(\.title) == [
            "Secret API_TOKEN was changed on GitHub on \(day)",
            "Variable BASE_URL was changed on GitHub",
            "Secret NEW_KEY was added on GitHub on \(day)",
            "Variable GONE was deleted on GitHub",
            "Environment qa was added on GitHub",
            "Environment old was deleted on GitHub",
            "Deployment branches of production were changed on GitHub",
        ])
        #expect(model.rows.map(\.scope).prefix(2) == ["Repository", "production"])
        #expect(model.rows[4].details == ["Contains QA_URL."])
        #expect(model.rows[0].keepLocal.title == "Keep Local")
        #expect(model.rows[0].acceptGitHub.title == "Accept GitHub")
        #expect(model.rows[0].acceptGitHub.explanation == "GitHub never returns secret values: enter the new value next.")
        // Only Accept GitHub of a remote deletion removes local data, so only it asks first.
        #expect(model.rows.map(\.acceptGitHub.needsConfirmation) == [false, false, false, true, false, true, false])
        #expect(model.rows.allSatisfy { !$0.keepLocal.needsConfirmation })
    }

    @Test func otherYearsShowTheYear() async throws {
        let date = try #require(DriftFixtures.october12(year: 2024))
        let now = try #require(DriftFixtures.october12(year: 2026))
        let fixture = try await Fixture(cached: DriftFixtures.report([
            DriftFixtures.item(.secretModified, .secret, "API_TOKEN", updatedAt: date),
        ]))
        fixture.harness.clock.setWallClock(to: now)
        await fixture.viewModel.load()
        let expected = date.formatted(.dateTime.month(.abbreviated).day().year())
        #expect(fixture.viewModel.rows.first?.title == "Secret API_TOKEN was changed on GitHub on \(expected)")
    }

    @Test func withoutACachedReportItChecksGitHub() async throws {
        let fixture = try await Fixture(
            cached: nil,
            refresh: .success(DriftFixtures.report([DriftFixtures.item(.remoteDeleted, .secret, "GONE")]))
        )
        await fixture.viewModel.load()
        #expect(fixture.service.refreshCount == 1)
        #expect(fixture.viewModel.rows.count == 1)
        #expect(!fixture.viewModel.isLoading)
    }

    @Test func refreshNeedsGitHub() async throws {
        let fixture = try await Fixture(cached: nil, isGitHubReady: false)
        await fixture.viewModel.load()
        #expect(fixture.service.refreshCount == 0)
        #expect(fixture.viewModel.alert?.message == DriftCopy.needsGH)
    }

    @Test func refreshFailureIsShown() async throws {
        let fixture = try await Fixture(cached: nil, refresh: .failure(.github(.rateLimited)))
        await fixture.viewModel.load()
        #expect(fixture.viewModel.alert?.message == GHError.rateLimited.localizedMessage)
        #expect(fixture.viewModel.report == nil)
    }

    @Test func secretAcceptGitHubContinuesInTheFillEditor() async throws {
        let itemID = ConfigItemID()
        let drift = DriftFixtures.item(.secretModified, .secret, "DB_PASSWORD", environment: "production", itemID: itemID)
        let fixture = try await Fixture(cached: DriftFixtures.report([drift]))
        let model = fixture.viewModel
        await model.load()

        await model.choose(drift.id, .acceptGitHub)
        #expect(fixture.service.resolutions == [FakeDriftService.Resolution(driftID: drift.id, option: .acceptGitHub)])
        #expect(model.rows.isEmpty)
        #expect(model.resolvedCount == 1)
        #expect(fixture.recorder.refreshes == [.drift(DriftFixtures.repositoryID)])
        #expect(fixture.recorder.presented == [.itemEditor(ItemEditorContext(
            repositoryID: DriftFixtures.repositoryID,
            scope: .environment(DriftFixtures.environmentID),
            mode: .fill(itemID),
            fillMatchesGitHub: true
        ))], "the user chose GitHub's value: the fill starts as already matching GitHub")

        // Closing the sheet does not refresh a second time.
        model.finish()
        #expect(fixture.recorder.refreshes.count == 1)
    }

    @Test func keepLocalResolvesWithoutAFollowUp() async throws {
        let drift = DriftFixtures.item(.variableModified, .variable, "BASE_URL")
        let fixture = try await Fixture(cached: DriftFixtures.report([drift]))
        let model = fixture.viewModel
        await model.load()

        await model.choose(drift.id, .keepLocal)
        #expect(fixture.service.resolutions == [FakeDriftService.Resolution(driftID: drift.id, option: .keepLocal)])
        #expect(fixture.recorder.presented.isEmpty)
        #expect(model.notice == DriftCopy.resolved)
        #expect(fixture.recorder.refreshes.isEmpty)
        model.finish()
        #expect(fixture.recorder.refreshes == [.drift(DriftFixtures.repositoryID)])
    }

    @Test func acceptingARemoteDeletionAsksFirst() async throws {
        let drift = DriftFixtures.item(.remoteDeleted, .secret, "GONE")
        let fixture = try await Fixture(cached: DriftFixtures.report([drift]))
        let model = fixture.viewModel
        await model.load()

        await model.choose(drift.id, .acceptGitHub)
        #expect(fixture.service.resolutions.isEmpty)
        let confirmation = try #require(model.confirmation)
        #expect(confirmation.title == "Delete GONE from your vault?")

        model.cancelConfirmation()
        #expect(model.confirmation == nil)
        #expect(fixture.service.resolutions.isEmpty)

        await model.choose(drift.id, .acceptGitHub)
        await model.confirm()
        #expect(fixture.service.resolutions == [FakeDriftService.Resolution(driftID: drift.id, option: .acceptGitHub)])
        #expect(model.rows.isEmpty)
    }

    @Test func unavailableKeepLocalOffersFillValue() async throws {
        let itemID = ConfigItemID()
        let drift = DriftFixtures.item(.secretModified, .secret, "API_TOKEN", itemID: itemID, keepLocalUnavailable: .valueMissing)
        let fixture = try await Fixture(cached: DriftFixtures.report([drift]))
        let model = fixture.viewModel
        await model.load()

        let row = try #require(model.rows.first)
        #expect(!row.keepLocal.isAvailable)
        #expect(row.keepLocal.unavailableReason == DriftCopy.unavailable(.valueMissing))
        await model.choose(drift.id, .keepLocal)
        #expect(fixture.service.resolutions.isEmpty)

        let fill = try #require(row.fillValue)
        model.fillValue(fill)
        #expect(fixture.recorder.presented == [.itemEditor(ItemEditorContext(
            repositoryID: DriftFixtures.repositoryID,
            scope: .repository,
            mode: .fill(itemID)
        ))])
        // Nothing was resolved, so the drift check is not repeated.
        #expect(fixture.recorder.refreshes.isEmpty)
    }

    @Test func staleResolutionExplainsAndChecksAgain() async throws {
        let drift = DriftFixtures.item(.variableModified, .variable, "BASE_URL")
        let fixture = try await Fixture(
            cached: DriftFixtures.report([drift]),
            refresh: .success(DriftFixtures.report([]))
        )
        fixture.service.failResolutions(with: .stale)
        let model = fixture.viewModel
        await model.load()

        await model.choose(drift.id, .keepLocal)
        #expect(model.alert?.message == DriftRepositoryError.stale.localizedMessage)
        #expect(fixture.service.refreshCount == 1)
        #expect(model.resolvedCount == 0)
        #expect(model.resolving.isEmpty)
    }

    @Test func notesListWhatWasNotCompared() async throws {
        var report = DriftFixtures.report([])
        report.unreadable = [ImportReadFailureModel(target: .secrets(environment: "production"), error: .adminRequired)]
        report.skippedNames = [SkippedRemoteNameModel(kind: .item(.variable), environment: nil, name: "bad-name")]
        report.expiredItems = [ConfigItemID()]
        let fixture = try await Fixture(cached: report)
        await fixture.viewModel.load()
        #expect(fixture.viewModel.notes == [
            "Secrets in production were not compared. \(GHError.adminRequired.localizedMessage)",
            "GitHub has names FX Vault cannot store, so they were not compared: bad-name.",
            "GitHub never confirmed 1 earlier pushes. They are pending again for the next Sync.",
        ])
    }

    @Test func driftLineCopy() {
        #expect(PlaceCopy.changedOnGitHub(1) == "1 changed on GitHub")
        #expect(PlaceCopy.changedOnGitHub(3) == "3 changed on GitHub")
        #expect(DriftCopy.bannerConflicts(2) == "2 also changed in your vault")
    }
}
