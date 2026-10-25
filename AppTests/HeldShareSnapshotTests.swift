import AppKit
import Foundation
import SwiftUI
import SyncEngine
import Testing
import VaultCore
@_spi(Testing) import VaultData
@testable import FXVault

/// Rendered PNGs of the held-import screens (v0.9.0): Sync's From Files review and the Held chip.
/// Moved from the 0.9 team snapshot suite when 1.0 removed teammates.
/// Opt-in like ``VisualSnapshotTests`` (`FXV_SNAPSHOTS_DIR`, or `TEST_RUNNER_FXV_SNAPSHOTS_DIR`
/// through xcodebuild). Nothing is asserted about pixels.
@MainActor
@Suite("Held share snapshots", .serialized, .enabled(if: SnapshotOutput.directory != nil, "set FXV_SNAPSHOTS_DIR to render"))
struct HeldShareSnapshotTests {
    private static let sheetSize = CGSize(width: Theme.Layout.syncSheetWidth, height: SnapshotOutput.sheetHeight)

    // MARK: - Sync › From Files

    private func syncSheet(held: [HeldShareModel], executable: [ConfigChangeModel]) async throws -> (TestHarness, SyncViewModel) {
        let harness = try await TestHarness(vault: .unlocked)
        var review = SyncFixtures.review([SyncFixtures.preflight(executable: executable)])
        review.heldShares = held
        let viewModel = SyncViewModel(
            context: SyncContext(repositoryIDs: nil),
            dependencies: harness.dependencies(recorder: ActionRecorder(), isGitHubReady: true),
            service: FakeSyncService(review: .success(review)),
            openURL: { _ in }
        )
        await viewModel.load()
        #expect(viewModel.step == .summary)
        return (harness, viewModel)
    }

    @Test func syncFromOneFile() async throws {
        let held = [HeldShareTests.share(HeldShareTests.first, sender: "Teammate A", verified: true, names: ["STRIPE_SECRET_KEY"])]
        let (harness, viewModel) = try await syncSheet(held: held, executable: [SyncFixtures.set(.secret, "SENTRY_DSN")])
        try await SnapshotOutput.write("sync-held-one", size: Self.sheetSize) {
            SyncScreen(viewModel: viewModel)
        }
        withExtendedLifetime(harness) {}
    }

    @Test func syncFromTwoFilesOneIncluded() async throws {
        let held = [
            HeldShareTests.share(HeldShareTests.first, sender: "Teammate A", verified: true, names: ["DATABASE_URL", "REDIS_URL"]),
            HeldShareTests.share(HeldShareTests.second, sender: "Contractor", verified: false, names: ["SUPABASE_ANON_KEY"]),
        ]
        let (harness, viewModel) = try await syncSheet(held: held, executable: [SyncFixtures.set(.secret, "SENTRY_DSN")])
        viewModel.setIncluded(HeldShareTests.first, true)
        try await SnapshotOutput.write("sync-held-two", size: Self.sheetSize) {
            SyncScreen(viewModel: viewModel)
        }
        withExtendedLifetime(harness) {}
    }

    @Test func syncWithOnlyHeldRows() async throws {
        let held = [HeldShareTests.share(HeldShareTests.first, sender: "Teammate A", verified: true, names: ["API_TOKEN"])]
        let (harness, viewModel) = try await syncSheet(held: held, executable: [])
        try await SnapshotOutput.write("sync-held-only", size: Self.sheetSize) {
            SyncScreen(viewModel: viewModel)
        }
        withExtendedLifetime(harness) {}
    }

    // MARK: - Held chip

    @Test func mainWindowHeldRow() async throws {
        let (harness, main) = try await MainSnapshotFixture.make()
        let detail = try #require(main.detail)
        let row = try #require(detail.rows.first { $0.status == .added } ?? detail.rows.first)
        try ShareHoldRepository(session: harness.vaultManager.session).hold(
            [row.id],
            under: HeldShareTests.first,
            senderName: "Teammate A",
            senderDeviceID: HeldShareTests.teammateDevice,
            importedAt: HeldShareTests.importedAt
        )
        #expect(await TestFixtures.eventually { detail.rows.contains { $0.id == row.id && $0.isHeld } })
        try await SnapshotOutput.write("main-held", size: SnapshotOutput.windowSize, isTitled: true) {
            MainScreen(viewModel: main)
        }
        withExtendedLifetime(harness) {}
    }
}
