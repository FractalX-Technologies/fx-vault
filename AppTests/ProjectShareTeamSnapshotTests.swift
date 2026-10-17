import AppKit
import Foundation
import SwiftUI
import SyncEngine
import Testing
import VaultCore
@_spi(Testing) import VaultData
@testable import FXVault

/// Rendered PNGs of the v0.9.0 screens owned by the team and sync parts of the app: Sync's From
/// Files review, the Held chip, Add Teammate › Not Nearby… and a teammate paired remotely.
/// Opt-in like ``VisualSnapshotTests`` (`FXV_SNAPSHOTS_DIR`, or `TEST_RUNNER_FXV_SNAPSHOTS_DIR`
/// through xcodebuild). Nothing is asserted about pixels.
@MainActor
@Suite("Project share snapshots (team and sync)", .serialized, .enabled(if: SnapshotOutput.directory != nil, "set FXV_SNAPSHOTS_DIR to render"))
struct ProjectShareTeamSnapshotTests {
    private static let sheetSize = CGSize(width: Theme.Layout.syncSheetWidth, height: SnapshotOutput.sheetHeight)
    private static let pairingWidth = Theme.Layout.addTeammateSheetWidth

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

    // MARK: - Not Nearby…

    @Test func remotePairingSteps() async throws {
        let macA = try await RemotePairingTests.Mac(RemotePairingTests.identityA)
        let macB = try await RemotePairingTests.Mac(RemotePairingTests.identityB)

        let invite = macA.pairing()
        try await write("pairing-start", invite, height: 440)
        invite.createInvitation()
        try await write("pairing-invitation-ready", invite, height: 300)

        let invitationData = try Data(contentsOf: try #require(invite.stagedFile))
        let invited = macB.pairing(file: invitationData)
        try await write("pairing-invitation", invited, height: 320)
        invited.createReply()
        try await write("pairing-reply-ready", invited, height: 620)

        let replyData = try Data(contentsOf: try #require(invited.stagedFile))
        let reply = macA.pairing(file: replyData)
        try await write("pairing-reply", reply, height: 560)
        reply.confirm()
        try await write("pairing-paired", reply, height: 260)

        invite.close()
        invited.close()
        reply.close()
    }

    @Test func teammatesSettingsWithARemoteTeammate() async throws {
        let macA = try await RemotePairingTests.Mac(RemotePairingTests.identityA)
        let macB = try await RemotePairingTests.Mac(RemotePairingTests.identityB)
        let invite = macA.pairing()
        invite.createInvitation()
        let invited = macB.pairing(file: try Data(contentsOf: try #require(invite.stagedFile)))
        invited.createReply()
        invited.confirm()
        let settings = TeammatesSettingsViewModel(app: macB.harness.app)
        #expect(await TestFixtures.eventually { settings.teammates.count == 1 })
        try await SnapshotOutput.write(
            "settings-teammates-paired-remotely",
            size: CGSize(width: Theme.Layout.settingsWidth, height: SnapshotOutput.settingsHeight)
        ) {
            TeammatesSettingsScreen(viewModel: settings)
        }
        invite.close()
        invited.close()
    }

    private func write(_ name: String, _ viewModel: RemotePairingViewModel, height: CGFloat) async throws {
        try await SnapshotOutput.write(name, size: CGSize(width: Self.pairingWidth, height: height)) {
            RemotePairingSheet(viewModel: viewModel)
                .background(Theme.Colors.card)
        }
    }
}
