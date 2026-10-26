import Foundation
import Testing
import VaultCore
@testable import FXVault

/// The menu bar item (1.0 M1, board MenuBar): Open FX Vault, and Review Sync, which opens the
/// Sync review now or after the unlock.
@MainActor
@Suite("Menu bar")
struct MenuBarTests {
    static let ready = GHStatusModel.ready(version: Limits.minimumGHVersion, path: "/opt/homebrew/bin/gh")

    @Test func reviewSyncNeedsSomethingPending() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: Self.ready)
        var openedWindow = 0
        harness.app.setMainWindowOpener { openedWindow += 1 }
        #expect(!harness.app.offersSyncReview)
        harness.app.requestSyncReview()
        #expect(!harness.app.isSyncReviewRequested)
        #expect(openedWindow == 0)

        harness.app.setPendingChangeCount(4)
        #expect(harness.app.offersSyncReview)
        #expect(MenuBarCopy.reviewSync(count: 4) == "Review Sync · 4 pending…")
    }

    @Test func reviewSyncIsHiddenDuringOnboarding() async throws {
        let harness = try await TestHarness(vault: .none, ghStatus: Self.ready)
        harness.app.setPendingChangeCount(2)
        #expect(!harness.app.offersSyncReview)
    }

    @Test func reviewSyncOpensTheSyncReview() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: Self.ready)
        var openedWindow = 0
        harness.app.setMainWindowOpener { openedWindow += 1 }
        let main = harness.app.makeMainViewModel()
        harness.app.setPendingChangeCount(3)

        harness.app.requestSyncReview()
        #expect(openedWindow == 1)
        main.presentRequestedSyncReview()
        #expect(main.activeSheet == .sync(SyncContext(repositoryIDs: nil)))
        #expect(!harness.app.isSyncReviewRequested)

        // Handled once: closing the review doesn't bring it back.
        main.activeSheet = nil
        #expect(main.activeSheet == nil)
    }

    /// Another sheet on screen keeps the request; the review follows when that sheet closes.
    @Test func reviewSyncWaitsForTheSheetOnScreen() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: Self.ready)
        let main = harness.app.makeMainViewModel()
        let other = MainSheet.shareImport(ShareImportContext(fileURL: URL(fileURLWithPath: "/private/tmp/fxvault-apptests/a.fxvault")))
        main.activeSheet = other
        harness.app.setPendingChangeCount(3)

        harness.app.requestSyncReview()
        main.presentRequestedSyncReview()
        #expect(main.activeSheet == other)

        main.activeSheet = nil
        #expect(main.activeSheet == .sync(SyncContext(repositoryIDs: nil)))
    }

    @Test func reviewSyncWhileLockedOpensAfterTheUnlock() async throws {
        let harness = try await TestHarness(vault: .locked, ghStatus: Self.ready)
        var openedWindow = 0
        harness.app.setMainWindowOpener { openedWindow += 1 }
        harness.app.setPendingChangeCount(2)

        harness.app.requestSyncReview()
        // Unit tests have no island: the window stands in for it.
        #expect(openedWindow == 1)
        #expect(!harness.app.takeSyncReviewRequest())
        #expect(harness.app.isSyncReviewRequested)

        try await harness.vaultManager.unlock(password: testPassword)
        harness.app.didUnlock()
        harness.app.setPendingChangeCount(2)
        let main = harness.app.makeMainViewModel()
        main.presentRequestedSyncReview()
        #expect(main.activeSheet == .sync(SyncContext(repositoryIDs: nil)))
    }

    /// A request still waiting (the window was closed) goes with the lock, like a relaunch.
    @Test func lockDropsAWaitingRequest() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: Self.ready)
        harness.app.setPendingChangeCount(2)
        harness.app.requestSyncReview()
        #expect(harness.app.isSyncReviewRequested)

        harness.app.lock(trigger: .manual)
        #expect(!harness.app.isSyncReviewRequested)

        try await harness.vaultManager.unlock(password: testPassword)
        harness.app.didUnlock()
        harness.app.setPendingChangeCount(2)
        let main = harness.app.makeMainViewModel()
        main.presentRequestedSyncReview()
        #expect(main.activeSheet == nil)
    }

    @Test func openFXVaultBringsTheWindow() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: Self.ready)
        var openedWindow = 0
        harness.app.setMainWindowOpener { openedWindow += 1 }
        harness.app.openFXVault()
        #expect(openedWindow == 1)

        harness.app.lock(trigger: .manual)
        harness.app.openFXVault()
        #expect(openedWindow == 2)
        #expect(harness.app.phase == .locked)
    }

    @Test func copyNamesTheApp() {
        #expect(MenuBarCopy.openApp == "Open \(AppIdentity.windowTitle)")
        #expect(MenuBarCopy.quit == "Quit \(AppIdentity.windowTitle)")
        #expect(MenuBarCopy.lockNow == "Lock Now")
        #expect(MenuBarCopy.settings == "Settings…")
    }
}
