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

    @Test func oneTouchInTheIslandUnlocksThroughItsOwnContext() async throws {
        let harness = try await Self.lockedWithTouchID()
        let lock = harness.app.lockScreen
        lock.prepareIslandTouchID()
        let session = try #require(lock.islandTouchID)
        await lock.unlockWithTouchID()
        #expect(harness.app.phase == .unlocked)
        #expect(harness.biometrics.evaluationCount == 1)
        #expect(harness.biometrics.loadCount == 1)
        #expect(harness.biometrics.lastLoadContext == ObjectIdentifier(session.context))
        #expect(lock.islandTouchID == nil)
    }

    @Test func aCancelledTouchReadsNothingAndTheIslandGetsAFreshCheck() async throws {
        let harness = try await Self.lockedWithTouchID()
        let lock = harness.app.lockScreen
        lock.prepareIslandTouchID()
        let first = try #require(lock.islandTouchID)
        harness.biometrics.failNextEvaluation(with: .cancelled)
        await lock.unlockWithTouchID()
        #expect(harness.app.phase == .locked)
        #expect(harness.biometrics.loadCount == 0)
        #expect(lock.error == nil)
        let second = try #require(lock.islandTouchID)
        #expect(second !== first)

        await lock.unlockWithTouchID()
        #expect(harness.app.phase == .unlocked)
    }

    /// A sleep or screen lock while the island is up runs Phase A only (already locked): the
    /// manager's lock invalidates the context, so the touch reads nothing and is never reused.
    @Test func aLockDuringTheTouchDropsTheIslandCheck() async throws {
        let harness = try await Self.lockedWithTouchID()
        let lock = harness.app.lockScreen
        lock.prepareIslandTouchID()
        let first = try #require(lock.islandTouchID)
        let app = harness.app
        harness.biometrics.onNextEvaluation {
            DispatchQueue.main.sync { MainActor.assumeIsolated { app.lock(trigger: .manual) } }
        }
        await lock.unlockWithTouchID()
        #expect(harness.app.phase == .locked)
        #expect(harness.biometrics.loadCount == 0)
        #expect(lock.islandTouchID !== first)
        await #expect(throws: VaultError.cancelled) {
            try await harness.vaultManager.unlockWithBiometrics(session: first)
        }
    }

    /// A sleep or screen lock while the island is up: Phase A only, yet one touch still unlocks
    /// and the next activation may prompt again.
    @Test func aSecondLockStillUnlocksWithOneTouch() async throws {
        let harness = try await Self.lockedWithTouchID()
        let lock = harness.app.lockScreen
        lock.prepareIslandTouchID()
        harness.biometrics.failNextEvaluation(with: .cancelled)
        await lock.autoPromptIfAllowed(isAppActive: true, isSceneActive: true)
        #expect(lock.hasAutoPrompted)

        harness.app.lock(trigger: .manual)
        #expect(!lock.hasAutoPrompted)
        let evaluations = harness.biometrics.evaluationCount
        await lock.unlockWithTouchID()
        #expect(harness.app.phase == .unlocked)
        #expect(harness.biometrics.evaluationCount == evaluations + 1)
    }

    /// The island showing again replaces a check a lock invalidated meanwhile, and keeps a live one.
    @Test func theIslandReplacesAStaleCheckWhenItShows() async throws {
        let harness = try await Self.lockedWithTouchID()
        let lock = harness.app.lockScreen
        lock.prepareIslandTouchID()
        let first = try #require(lock.islandTouchID)
        lock.prepareIslandTouchID()
        #expect(lock.islandTouchID === first)

        harness.vaultManager.lock()
        lock.prepareIslandTouchID()
        #expect(lock.islandTouchID !== first)
        await lock.unlockWithTouchID()
        #expect(harness.app.phase == .unlocked)
        #expect(harness.biometrics.evaluationCount == 1)
    }

    @Test func withoutTheIslandTouchIDUsesTheSystemPrompt() async throws {
        let harness = try await Self.lockedWithTouchID()
        let lock = harness.app.lockScreen
        lock.prepareIslandTouchID()
        lock.dropIslandTouchID()
        await lock.unlockWithTouchID()
        #expect(harness.app.phase == .unlocked)
        #expect(harness.biometrics.evaluationCount == 0)
        #expect(harness.biometrics.loadCount == 1)
    }

    @Test func withoutTouchIDTheIslandHasNoCheck() async throws {
        let harness = try await TestHarness(vault: .locked)
        harness.app.lockScreen.prepareIslandTouchID()
        #expect(harness.app.lockScreen.islandTouchID == nil)
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
