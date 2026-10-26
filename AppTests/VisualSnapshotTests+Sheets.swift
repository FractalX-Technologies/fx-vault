import AppKit
import Foundation
import SwiftUI
import SyncEngine
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// The 1.0 dialogs compared with their boards (D6d): rendered like the rest of
/// ``VisualSnapshotTests`` (the same suite, opt-in through `FXV_SNAPSHOTS_DIR`).
extension VisualSnapshotTests {
    // MARK: - Sync (boards Sync-Delete, Sync-Progress, Sync-Done)

    /// The deletion check, the run half way (a check, a spinner, rings, a blocked line, the
    /// deletions last) and the short finish.
    @Test func syncRunAndFinish() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let production = "production"
        let flags = SyncFixtures.set(.variable, "FEATURE_FLAGS", environment: production)
        let level = SyncFixtures.set(.variable, "LOG_LEVEL", environment: production, isNew: false, reason: .modified)
        let jwt = SyncFixtures.set(.secret, "JWT_SECRET", environment: production, isNew: false, reason: .modified)
        let sentry = SyncFixtures.set(.secret, "SENTRY_DSN")
        let legacy = SyncFixtures.deleteItem(.secret, "LEGACY_TOKEN")
        let review = SyncFixtures.review([SyncFixtures.preflight(
            executable: [flags, level, jwt, sentry, legacy],
            blocked: [SyncBlockedChangeModel(
                change: SyncFixtures.set(.secret, "DOCKER_PASSWORD", environment: production),
                reason: .change(.valueMissing)
            )]
        )])
        let service = FakeSyncService(review: .success(review))
        service.setPreviews([RepoDeletionPreviewModel(
            repositoryID: SyncFixtures.repository.id,
            fullName: SyncFixtures.fullName,
            itemDeletions: [legacy],
            environments: []
        )])
        let viewModel = SyncViewModel(
            context: SyncContext(repositoryIDs: nil),
            dependencies: harness.dependencies(recorder: ActionRecorder(), isGitHubReady: true),
            service: service,
            openURL: { _ in }
        )
        await viewModel.load()
        await viewModel.reviewDeletions()
        #expect(viewModel.deletionTitle == "Delete 1 secret?")
        try await SnapshotOutput.write("sync-deletions", size: CGSize(width: Theme.Layout.syncSheetWidth, height: Self.syncDeletionsHeight)) {
            SyncScreen(viewModel: viewModel)
        }

        viewModel.deletionsAcknowledged = true
        let run = Task { await viewModel.startSync(includeDeletions: true) }
        #expect(await TestFixtures.eventually { viewModel.step == .progress })
        service.run.send(.started(total: 5))
        for change in [flags, level] {
            service.run.send(.changeStarted(changeID: change.id))
            service.run.send(.changeFinished(SyncChangeResultModel(change: change, outcome: .succeeded(.verified)), completed: 1, total: 5))
        }
        service.run.send(.changeStarted(changeID: jwt.id))
        let jwtLine = try #require(viewModel.progressCards.flatMap(\.lines).first { $0.name == "JWT_SECRET" })
        #expect(await TestFixtures.eventually { viewModel.lineState(jwtLine) == .writing })
        try await SnapshotOutput.write("sync-progress", size: CGSize(width: Theme.Layout.syncSheetWidth, height: Self.syncProgressHeight)) {
            SyncScreen(viewModel: viewModel)
        }

        service.run.finish(SyncFixtures.outcome(
            [flags, level, jwt, sentry, legacy].map { SyncChangeResultModel(change: $0, outcome: .succeeded(.verified)) }
        ))
        await run.value
        #expect(viewModel.done?.syncedCount == 5)
        try await SnapshotOutput.write("sync-done", size: CGSize(width: Theme.Layout.syncDoneWidth, height: Self.syncDoneHeight)) {
            SyncScreen(viewModel: viewModel)
        }
    }

    private static let syncDeletionsHeight: CGFloat = 320
    private static let syncProgressHeight: CGFloat = 520
    private static let syncDoneHeight: CGFloat = 260
}
