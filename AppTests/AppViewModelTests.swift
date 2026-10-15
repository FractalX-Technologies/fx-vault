import SyncEngine
import Testing
import VaultCore
import VaultData
@testable import FXVault

@MainActor
@Suite("AppViewModel")
struct AppViewModelTests {
    @Test(arguments: [
        (TestVaultState.none, VaultPhase.onboarding),
        (.locked, .locked),
        (.unlocked, .unlocked),
    ])
    func initialPhaseFollowsVaultState(_ state: TestVaultState, _ phase: VaultPhase) async throws {
        let harness = try await TestHarness(vault: state)
        #expect(harness.app.phase == phase)
    }

    @Test func manualLockRunsBothPhases() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        harness.container.clipboard.copy("FXV_FIXTURE_VALUE")
        harness.app.lock(trigger: .manual)
        #expect(harness.vaultManager.session.isLocked)
        #expect(harness.app.phase == .locked)
        #expect(harness.app.lockCount == 1)
        #expect(harness.app.lastLockTrigger == .manual)
        #expect(harness.pasteboardString == nil)
    }

    @Test func didUnlockRequiresKeys() async throws {
        let harness = try await TestHarness(vault: .locked)
        harness.app.didUnlock()
        #expect(harness.app.phase == .locked)
        try await harness.vaultManager.unlock(password: testPassword)
        harness.app.didUnlock()
        #expect(harness.app.phase == .unlocked)
    }

    @Test func pendingCountDrivesDockBadge() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        harness.app.setPendingChangeCount(5)
        #expect(harness.app.pendingChangeCount == 5)
        #expect(harness.dockBadge.count == 5)
        harness.app.setPendingChangeCount(-1)
        #expect(harness.dockBadge.count == 0)
    }

    @Test func ghStatusComesFromTheProbe() async throws {
        let status = GHStatusModel.outdated(found: "2.90.0", required: Limits.minimumGHVersion)
        let harness = try await TestHarness(ghStatus: status)
        await harness.app.refreshGHStatus()
        #expect(harness.app.ghStatus == status)
    }

    @Test func terminateClearsClipboardAndLocks() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        harness.container.clipboard.copy("FXV_FIXTURE_VALUE")
        harness.app.applicationWillTerminate()
        #expect(harness.pasteboardString == nil)
        #expect(harness.vaultManager.session.isLocked)
        #expect(!harness.container.autoLock.isRunning)
    }

    @Test func lockPurgesTheTokenCacheTheGitHubRepositoryUses() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let cache = harness.data.github.tokenCache
        cache.store(SecretBytes(utf8: TestFixtures.token), for: TestFixtures.account)
        #expect(cache.count == 1)
        harness.app.lock(trigger: .manual)
        #expect(cache.count == 0)
    }

    @Test func unlockRunsLaunchReconciliation() async throws {
        let harness = try await TestHarness(vault: .locked)
        #expect(harness.app.lastReconciliation == nil)
        try await harness.vaultManager.unlock(password: testPassword)
        harness.app.didUnlock()
        await harness.app.reconciliationTask?.value
        #expect(harness.app.lastReconciliation == SyncReconciliationModel())
    }

    @Test func pendingCountFollowsTheVault() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        #expect(harness.app.pendingChangeCount == 0)
        try await harness.stageRepository(items: [TestFixtures.item(.variable, "BASE_URL", "https://example.com")])
        let updated = await TestFixtures.eventually { harness.app.pendingChangeCount > 0 }
        #expect(updated)
        #expect(harness.dockBadge.count == harness.app.pendingChangeCount)
    }
}
