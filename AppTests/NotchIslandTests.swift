import CoreGraphics
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
