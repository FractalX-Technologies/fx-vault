import CoreGraphics
import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// The notch island that replaces the lock window (tasks/todo.md B11e).
@MainActor
@Suite("Notch island")
struct NotchIslandTests {
    static let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    static let size = CGSize(width: Theme.Layout.islandWidth, height: 120)

    @Test func withANotchTheIslandHangsFromTheTopCenter() {
        let frame = NotchGeometry.islandFrame(
            size: Self.size,
            screenFrame: Self.screen,
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            notchHeight: 38
        )
        #expect(frame.maxY == Self.screen.maxY)
        #expect(frame.midX == Self.screen.midX)
        #expect(frame.size == Self.size)
    }

    @Test func withoutANotchItFloatsUnderTheMenuBar() {
        let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let frame = NotchGeometry.islandFrame(
            size: Self.size,
            screenFrame: external,
            visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415),
            notchHeight: 0
        )
        #expect(frame.maxY == 1415 - Theme.Layout.islandMenuBarGap)
        #expect(frame.midX == external.midX)
    }

    // MARK: - Growing out of the notch

    @Test func theNotchIsTheScreenMinusTheAreasBesideIt() {
        let left = CGRect(x: 0, y: 944, width: 662, height: 38)
        let right = CGRect(x: 850, y: 944, width: 662, height: 38)
        #expect(NotchGeometry.notchWidth(screenWidth: 1512, leftArea: left, rightArea: right) == 188)
        #expect(
            NotchGeometry.notchWidth(screenWidth: 1512, leftArea: nil, rightArea: nil) == 0,
            "Without a notch the island grows from a point"
        )
    }

    @Test func theIslandGrowsFromTheNotchToItsWholeFrame() {
        let rect = CGRect(x: 0, y: 0, width: 340, height: 120)
        let start = NotchRevealShape.outline(progress: 0, in: rect, startWidth: 188, startHeight: 38)
        #expect(start == CGRect(x: 76, y: 0, width: 188, height: 38), "It starts as the notch itself")
        let half = NotchRevealShape.outline(progress: 0.5, in: rect, startWidth: 188, startHeight: 38)
        #expect(half == CGRect(x: 38, y: 0, width: 264, height: 79), "Centered, hung from the top")
        #expect(NotchRevealShape.outline(progress: 1, in: rect, startWidth: 188, startHeight: 38) == rect)
        #expect(
            NotchRevealShape.outline(progress: 1.1, in: rect, startWidth: 188, startHeight: 38) == rect,
            "A spring's overshoot never draws past the panel"
        )
    }

    @Test func aNewShowStartsCollapsed() async throws {
        let harness = try await TestHarness(vault: .locked)
        let model = NotchIslandModel(lock: harness.app.lockScreen)
        model.isRevealed = true
        model.reset()
        #expect(!model.isRevealed)
    }

    @Test func touchIDFirstThenPasswordThenUnlocked() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        try await harness.enableTouchID()
        harness.app.lock(trigger: .manual)
        let model = NotchIslandModel(lock: harness.app.lockScreen)
        #expect(model.state == .touchID)
        model.prefersPassword = true
        #expect(model.state == .password)
        model.isUnlocked = true
        #expect(model.state == .unlocked)
        model.reset()
        #expect(model.state == .touchID, "A new lock starts on Touch ID again")
    }

    @Test func withoutTouchIDTheIslandAsksForThePassword() async throws {
        let harness = try await TestHarness(vault: .locked)
        let model = NotchIslandModel(lock: harness.app.lockScreen)
        #expect(model.state == .password)
    }

    // MARK: - Touch ID in the island (1.0 B11e2)

    private static func lockedWithTouchID() async throws -> TestHarness {
        let harness = try await TestHarness(vault: .unlocked)
        harness.preferences.hasAnsweredTouchIDOffer = true
        try await harness.enableTouchID()
        harness.app.lock(trigger: .manual)
        return harness
    }

    /// The island's row opens the system Touch ID prompt (1.0.2): the embedded
    /// `LAAuthenticationView` cancelled its own check before any touch, so it was dropped.
    @Test func oneTouchInTheIslandUnlocksThroughTheSystemPrompt() async throws {
        let harness = try await Self.lockedWithTouchID()
        let lock = harness.app.lockScreen
        await lock.unlockWithTouchID()
        #expect(harness.app.phase == .unlocked)
        #expect(harness.biometrics.evaluationCount == 0, "No embedded check")
        #expect(harness.biometrics.loadCount == 1)
        #expect(harness.biometrics.lastPrompt == LockViewModel.unlockPrompt)
    }

    @Test func aCancelledTouchLeavesItLockedAndTheNextTouchUnlocks() async throws {
        let harness = try await Self.lockedWithTouchID()
        let lock = harness.app.lockScreen
        harness.biometrics.failNextLoad(with: .cancelled)
        await lock.unlockWithTouchID()
        #expect(harness.app.phase == .locked)
        #expect(lock.error == nil)

        await lock.unlockWithTouchID()
        #expect(harness.app.phase == .unlocked)
    }

    /// A sleep or screen lock while the island is up: Phase A only, yet one touch still unlocks
    /// and the next activation may prompt again.
    @Test func aSecondLockStillUnlocksWithOneTouch() async throws {
        let harness = try await Self.lockedWithTouchID()
        let lock = harness.app.lockScreen
        harness.biometrics.failNextLoad(with: .cancelled)
        await lock.autoPromptIfAllowed(isAppActive: true, isSceneActive: true)
        #expect(lock.hasAutoPrompted)

        harness.app.lock(trigger: .manual)
        #expect(!lock.hasAutoPrompted)
        await lock.unlockWithTouchID()
        #expect(harness.app.phase == .unlocked)
    }

    /// The island closes the window of a locked vault, and that close is a lock trigger; it must
    /// leave Touch ID working.
    @Test func closingTheWindowOfALockedVaultKeepsTouchID() async throws {
        let harness = try await Self.lockedWithTouchID()
        let lock = harness.app.lockScreen
        harness.app.lock(trigger: .windowClosed)
        await lock.unlockWithTouchID()
        #expect(harness.app.phase == .unlocked)
    }

    /// Tests have no side effects: no island, and the window keeps the lock screen. The shared
    /// lock model still unlocks and resets on the next lock.
    @Test func theSharedLockModelUnlocksAndResetsOnLock() async throws {
        let harness = try await TestHarness(vault: .locked)
        harness.preferences.hasAnsweredTouchIDOffer = true
        #expect(harness.app.island == nil)
        let lock = harness.app.lockScreen
        #expect(lock === harness.app.lockScreen)
        lock.password = testPassword
        await lock.unlockWithPassword()
        #expect(harness.app.phase == .unlocked)

        harness.app.lock(trigger: .manual)
        lock.showRecoveryReset()
        #expect(lock.isShowingRecoveryReset)
        lock.recoveryResetDidCancel()
        #expect(!lock.isShowingRecoveryReset)
        #expect(harness.app.phase == .locked)
    }
}
