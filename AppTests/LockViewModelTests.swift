import Testing
import VaultCore
import VaultData
@testable import FXVault

@MainActor
@Suite("LockViewModel")
struct LockViewModelTests {
    @Test func wrongPasswordShowsIncorrectPassword() async throws {
        let harness = try await TestHarness(vault: .locked)
        let viewModel = LockViewModel(app: harness.app)
        #expect(harness.app.phase == .locked)
        viewModel.password = otherTestPassword
        await viewModel.unlockWithPassword()
        #expect(viewModel.error == VaultError.wrongPassword.presentation)
        #expect(viewModel.error?.title == "Incorrect password")
        #expect(harness.app.phase == .locked)
        #expect(harness.vaultManager.state == .locked)
    }

    @Test func correctPasswordUnlocks() async throws {
        let harness = try await TestHarness(vault: .locked)
        harness.preferences.hasAnsweredTouchIDOffer = true
        let viewModel = LockViewModel(app: harness.app)
        #expect(!viewModel.canUnlockWithPassword)
        viewModel.password = testPassword
        #expect(viewModel.canUnlockWithPassword)
        await viewModel.unlockWithPassword()
        #expect(viewModel.error == nil)
        #expect(viewModel.password.isEmpty)
        #expect(harness.app.phase == .unlocked)
        #expect(harness.vaultManager.state == .unlocked)
    }

    @Test func touchIDButtonHiddenWhenNotEnabled() async throws {
        let harness = try await TestHarness(vault: .locked)
        let viewModel = LockViewModel(app: harness.app)
        #expect(!viewModel.showsTouchIDButton)
        #expect(viewModel.biometricNotice == nil)
        await viewModel.autoPromptIfAllowed(isAppActive: true, isSceneActive: true)
        #expect(harness.biometrics.loadCount == 0)
        #expect(!viewModel.hasAutoPrompted)
    }

    @Test func autoPromptsOnceOnlyWhenActive() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        try await harness.enableTouchID()
        harness.app.lock(trigger: .manual)
        let viewModel = LockViewModel(app: harness.app)
        #expect(viewModel.showsTouchIDButton)

        await viewModel.autoPromptIfAllowed(isAppActive: false, isSceneActive: true)
        await viewModel.autoPromptIfAllowed(isAppActive: true, isSceneActive: false)
        #expect(harness.biometrics.loadCount == 0)

        await viewModel.autoPromptIfAllowed(isAppActive: true, isSceneActive: true)
        #expect(harness.biometrics.loadCount == 1)
        #expect(harness.biometrics.lastPrompt == LockViewModel.unlockPrompt)
        #expect(harness.app.phase == .unlocked)

        harness.app.lock(trigger: .manual)
        // A lock resets the once-per-lock rule.
        #expect(!viewModel.hasAutoPrompted)
    }

    @Test func autoPromptHappensOnlyOncePerLock() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        try await harness.enableTouchID()
        harness.app.lock(trigger: .manual)
        let viewModel = LockViewModel(app: harness.app)
        harness.biometrics.failNextLoad(with: .cancelled)
        await viewModel.autoPromptIfAllowed(isAppActive: true, isSceneActive: true)
        #expect(viewModel.error == nil)
        #expect(harness.app.phase == .locked)
        await viewModel.autoPromptIfAllowed(isAppActive: true, isSceneActive: true)
        #expect(harness.biometrics.loadCount == 1)
    }

    @Test func passwordFallbackFocusesThePasswordFieldWithoutAnError() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        try await harness.enableTouchID()
        harness.app.lock(trigger: .manual)
        let viewModel = LockViewModel(app: harness.app)
        #expect(viewModel.passwordFocusRequest == 0)
        harness.biometrics.failNextLoad(with: .passwordFallbackRequested)
        await viewModel.unlockWithTouchID()
        #expect(viewModel.error == nil)
        #expect(viewModel.passwordFocusRequest == 1)
        #expect(viewModel.showsTouchIDButton)
        #expect(harness.app.phase == .locked)
    }

    @Test func restartRequiresPasswordAndNeverPrompts() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        try await harness.enableTouchID()
        harness.app.lock(trigger: .manual)
        harness.capabilities.bootSession = "00000000-0000-4000-8000-00000000b002"
        let viewModel = LockViewModel(app: harness.app)
        #expect(!viewModel.showsTouchIDButton)
        #expect(viewModel.passwordRequiredReason == .restart)
        #expect(viewModel.biometricNotice?.detail == PasswordRequiredReason.restart.localizedMessage)
        #expect(viewModel.biometricNotice?.title == "Password required: After a restart")
        await viewModel.autoPromptIfAllowed(isAppActive: true, isSceneActive: true)
        #expect(harness.biometrics.loadCount == 0)
    }

    @Test func fourteenDayRuleRequiresPassword() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        try await harness.enableTouchID()
        harness.app.lock(trigger: .manual)
        harness.clock.advance(by: Timeouts.passwordMaxAge + .seconds(1))
        let viewModel = LockViewModel(app: harness.app)
        #expect(viewModel.passwordRequiredReason == .periodic)
        #expect(!viewModel.showsTouchIDButton)
    }

    @Test func invalidatedTouchIDShowsMessageAndFallsBackToPassword() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        try await harness.enableTouchID()
        harness.app.lock(trigger: .manual)
        let viewModel = LockViewModel(app: harness.app)
        harness.biometrics.failNextLoad(with: .biometryInvalidated)
        await viewModel.unlockWithTouchID()
        #expect(viewModel.error == VaultError.biometryInvalidated.presentation)
        #expect(harness.app.phase == .locked)
        viewModel.password = testPassword
        await viewModel.unlockWithPassword()
        // Touch ID turned itself off: the offer to turn it on again comes first.
        let offer = try #require(viewModel.touchIDOffer)
        #expect(offer.isAfterInvalidation)
        offer.notNow()
        #expect(harness.app.phase == .unlocked)
    }

    @Test func recoveryResetRouteAndLockReset() async throws {
        let harness = try await TestHarness(vault: .locked)
        let viewModel = LockViewModel(app: harness.app)
        viewModel.password = "typed"
        viewModel.showRecoveryReset()
        #expect(viewModel.isShowingRecoveryReset)
        #expect(viewModel.password.isEmpty)
        viewModel.recoveryResetDidCancel()
        #expect(!viewModel.isShowingRecoveryReset)

        viewModel.password = "typed"
        viewModel.vaultDidLock()
        #expect(viewModel.password.isEmpty)
    }
}
