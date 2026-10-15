import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// The one-time "Unlock FX Vault with Touch ID" offer after a password unlock, and the lock
/// screen's Touch ID notes (v0.1.1).
@MainActor
@Suite("Touch ID offer and lock-screen reasons")
struct TouchIDOfferTests {
    /// A locked harness and a lock view model that unlocked with the password.
    private func unlockWithPassword(_ harness: TestHarness) async -> LockViewModel {
        let viewModel = LockViewModel(app: harness.app)
        viewModel.password = testPassword
        await viewModel.unlockWithPassword()
        return viewModel
    }

    // MARK: - When the offer appears

    @Test func passwordUnlockOffersTouchIDOnceBeforeTheMainWindow() async throws {
        let harness = try await TestHarness(vault: .locked)
        let viewModel = await unlockWithPassword(harness)

        let offer = try #require(viewModel.touchIDOffer)
        #expect(!offer.isAfterInvalidation)
        #expect(offer.canEnable)
        #expect(viewModel.password.isEmpty)
        // The vault is open; the main window waits for the answer.
        #expect(harness.vaultManager.state == .unlocked)
        #expect(harness.app.phase == .locked)

        offer.notNow()
        #expect(viewModel.touchIDOffer == nil)
        #expect(offer.isFinished)
        #expect(!offer.canEnable)
        #expect(harness.app.phase == .unlocked)
        #expect(harness.preferences.hasAnsweredTouchIDOffer)
        #expect(try !harness.vaultManager.isBiometricsEnabled())
    }

    @Test func notNowIsRememberedAcrossUnlocks() async throws {
        let harness = try await TestHarness(vault: .locked)
        let first = await unlockWithPassword(harness)
        try #require(first.touchIDOffer).notNow()

        harness.app.lock(trigger: .manual)
        let second = await unlockWithPassword(harness)
        #expect(second.touchIDOffer == nil)
        #expect(harness.app.phase == .unlocked)
    }

    @Test func enableTurnsOnTouchIDWithThePasswordJustTyped() async throws {
        let harness = try await TestHarness(vault: .locked)
        let viewModel = await unlockWithPassword(harness)
        let offer = try #require(viewModel.touchIDOffer)

        await offer.enable()
        #expect(offer.error == nil)
        #expect(offer.isFinished)
        #expect(viewModel.touchIDOffer == nil)
        #expect(harness.app.phase == .unlocked)
        #expect(try harness.vaultManager.isBiometricsEnabled())
        #expect(harness.biometrics.accounts.count == 1)
        #expect(harness.preferences.hasAnsweredTouchIDOffer)

        // Enabled: the next lock offers the Touch ID button, and the offer never comes back.
        harness.app.lock(trigger: .manual)
        let next = LockViewModel(app: harness.app)
        #expect(next.showsTouchIDButton)
        #expect(next.subtitle == "Use Touch ID or enter your master password.")
        next.password = testPassword
        await next.unlockWithPassword()
        #expect(next.touchIDOffer == nil)
        #expect(harness.app.phase == .unlocked)
    }

    @Test func unsignedBuildNeverOffersTouchID() async throws {
        let harness = try await TestHarness(vault: .locked, signed: false)
        let viewModel = await unlockWithPassword(harness)
        #expect(viewModel.touchIDOffer == nil)
        #expect(harness.app.phase == .unlocked)
        #expect(!harness.preferences.hasAnsweredTouchIDOffer)
    }

    @Test(arguments: [BiometryUnavailableReason.notEnrolled, .notAvailable, .lockout, .passcodeNotSet])
    func unavailableBiometryNeverOffersTouchID(_ reason: BiometryUnavailableReason) async throws {
        let harness = try await TestHarness(vault: .locked)
        harness.capabilities.unavailableReason = reason
        let viewModel = await unlockWithPassword(harness)
        #expect(viewModel.touchIDOffer == nil)
        #expect(harness.app.phase == .unlocked)
    }

    @Test func wrongPasswordShowsNoOffer() async throws {
        let harness = try await TestHarness(vault: .locked)
        let viewModel = LockViewModel(app: harness.app)
        viewModel.password = otherTestPassword
        await viewModel.unlockWithPassword()
        #expect(viewModel.touchIDOffer == nil)
        #expect(harness.vaultManager.state == .locked)
    }

    @Test func eligibilityRules() async throws {
        let harness = try await TestHarness(vault: .locked)
        // Locked: never.
        #expect(!harness.app.shouldOfferTouchID(afterInvalidation: true))

        try await harness.vaultManager.unlock(password: testPassword)
        #expect(harness.app.shouldOfferTouchID(afterInvalidation: false))

        harness.app.recordTouchIDOfferAnswer()
        #expect(!harness.app.shouldOfferTouchID(afterInvalidation: false))
        // Touch ID just turned itself off (enrollment change): offered once more.
        #expect(harness.app.shouldOfferTouchID(afterInvalidation: true))

        try await harness.enableTouchID()
        #expect(!harness.app.shouldOfferTouchID(afterInvalidation: true))
    }

    // MARK: - Lock and failures

    @Test func lockWhileTheOfferIsShownDropsItWithoutAnAnswer() async throws {
        let harness = try await TestHarness(vault: .locked)
        let viewModel = await unlockWithPassword(harness)
        let offer = try #require(viewModel.touchIDOffer)

        harness.signals.send(.screenLocked)

        #expect(harness.vaultManager.state == .locked)
        #expect(harness.app.phase == .locked)
        #expect(viewModel.touchIDOffer == nil)
        #expect(offer.isFinished)
        #expect(!offer.canEnable)
        #expect(!harness.preferences.hasAnsweredTouchIDOffer)
        await offer.enable()
        #expect(try !harness.vaultManager.isBiometricsEnabled())
        #expect(harness.app.phase == .locked)
    }

    @Test func failedEnableShowsTheErrorAndContinueCountsAsNotNow() async throws {
        let harness = try await TestHarness(vault: .locked)
        harness.biometrics.failStores(with: .biometryUnavailable(.notAvailable))
        let viewModel = await unlockWithPassword(harness)
        let offer = try #require(viewModel.touchIDOffer)

        await offer.enable()
        #expect(offer.error == VaultError.biometryUnavailable(.notAvailable).presentation)
        #expect(!offer.isFinished)
        // The password was used once and dropped: no retry from here.
        #expect(!offer.canEnable)
        #expect(harness.app.phase == .locked)
        #expect(!harness.preferences.hasAnsweredTouchIDOffer)

        offer.notNow()
        #expect(harness.app.phase == .unlocked)
        #expect(harness.preferences.hasAnsweredTouchIDOffer)
    }

    @Test func enrollmentChangeOffersTouchIDAgainAfterThePassword() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        try await harness.enableTouchID()
        harness.app.recordTouchIDOfferAnswer()
        harness.app.lock(trigger: .manual)
        harness.capabilities.stateHash = Data("enrollment-b".utf8)

        let viewModel = LockViewModel(app: harness.app)
        #expect(viewModel.passwordRequiredReason == .biometryChanged)
        #expect(viewModel.biometricNotice?.title == "Password required: Fingerprints changed")
        viewModel.password = testPassword
        await viewModel.unlockWithPassword()

        let offer = try #require(viewModel.touchIDOffer)
        #expect(offer.isAfterInvalidation)
        #expect(try !harness.vaultManager.isBiometricsEnabled())
        await offer.enable()
        #expect(try harness.vaultManager.isBiometricsEnabled())
        #expect(harness.app.phase == .unlocked)
    }

    /// The restart and 14-day rules are checked before the enrollment, so the lock screen shows
    /// those reasons while the password unlock still turns Touch ID off (T-1).
    @Test(arguments: [PasswordRequiredReason.restart, .periodic])
    func enrollmentChangeBehindAnotherReasonStillOffersTouchIDAgain(_ reason: PasswordRequiredReason) async throws {
        let harness = try await TestHarness(vault: .unlocked)
        try await harness.enableTouchID()
        harness.app.recordTouchIDOfferAnswer()
        harness.app.lock(trigger: .manual)
        harness.capabilities.stateHash = Data("enrollment-b".utf8)
        switch reason {
        case .restart:
            harness.capabilities.bootSession = "00000000-0000-4000-8000-00000000b002"
        case .periodic, .biometryChanged:
            harness.clock.advance(by: Timeouts.passwordMaxAge + .seconds(1))
        }

        let viewModel = LockViewModel(app: harness.app)
        #expect(viewModel.passwordRequiredReason == reason)
        viewModel.password = testPassword
        await viewModel.unlockWithPassword()

        let offer = try #require(viewModel.touchIDOffer)
        #expect(offer.isAfterInvalidation)
        #expect(try !harness.vaultManager.isBiometricsEnabled())
        offer.notNow()
        #expect(harness.app.phase == .unlocked)
        #expect(!harness.vaultManager.isBiometricsTurnedOffAutomatically)

        // Answered: the next password unlock does not ask again.
        harness.app.lock(trigger: .manual)
        let next = await unlockWithPassword(harness)
        #expect(next.touchIDOffer == nil)
    }

    /// The enrollment changed after the lock screen refreshed; a Touch ID attempt turns Touch ID
    /// off, says so, and the password unlock offers it again (T-2).
    @Test func enrollmentChangeSeenByATouchIDAttemptIsExplainedAndOfferedAgain() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        try await harness.enableTouchID()
        harness.app.recordTouchIDOfferAnswer()
        harness.app.lock(trigger: .manual)
        let viewModel = LockViewModel(app: harness.app)
        #expect(viewModel.showsTouchIDButton)

        harness.capabilities.stateHash = Data("enrollment-b".utf8)
        await viewModel.unlockWithTouchID()
        #expect(viewModel.error == VaultError.biometryInvalidated.presentation)
        #expect(!viewModel.showsTouchIDButton)
        #expect(try !harness.vaultManager.isBiometricsEnabled())

        viewModel.password = testPassword
        await viewModel.unlockWithPassword()
        let offer = try #require(viewModel.touchIDOffer)
        #expect(offer.isAfterInvalidation)
    }

    /// A ReauthGate check while unlocked turned Touch ID off; the next lock and password unlock
    /// offer it again (T-2).
    @Test func enrollmentChangeSeenWhileUnlockedIsOfferedAgainAfterTheNextLock() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        try await harness.enableTouchID()
        harness.app.recordTouchIDOfferAnswer()
        harness.capabilities.stateHash = Data("enrollment-b".utf8)
        await #expect(throws: VaultError.passwordRequired(reason: .biometryChanged)) {
            try await ReauthGate(manager: harness.vaultManager).authorize(.export, with: .biometrics(LockViewModel.unlockPrompt))
        }

        harness.app.lock(trigger: .manual)
        let viewModel = await unlockWithPassword(harness)
        let offer = try #require(viewModel.touchIDOffer)
        #expect(offer.isAfterInvalidation)
    }

    @Test func settingsToggleAnswersTheOffer() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let settings = SecuritySettingsViewModel(app: harness.app)
        settings.requestTouchID(enabled: true)
        settings.currentPassword = testPassword
        await settings.confirmTouchIDChange()
        #expect(settings.isBiometricsEnabled)
        #expect(harness.preferences.hasAnsweredTouchIDOffer)

        // Turned off in Settings on purpose: the unlock offer does not nag afterwards.
        settings.requestTouchID(enabled: false)
        settings.currentPassword = testPassword
        await settings.confirmTouchIDChange()
        #expect(!settings.isBiometricsEnabled)
        harness.app.lock(trigger: .manual)
        let viewModel = await unlockWithPassword(harness)
        #expect(viewModel.touchIDOffer == nil)
    }

    // MARK: - Lock-screen reasons

    @Test func shortReasonStrings() {
        #expect(PasswordRequiredReason.restart.localizedShortTitle == "After a restart")
        #expect(PasswordRequiredReason.periodic.localizedShortTitle == "Every 14 days")
        #expect(PasswordRequiredReason.biometryChanged.localizedShortTitle == "Fingerprints changed")
    }

    @Test func restartReasonUnderThePasswordField() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        try await harness.enableTouchID()
        harness.app.lock(trigger: .manual)
        harness.capabilities.bootSession = "00000000-0000-4000-8000-00000000b002"
        let viewModel = LockViewModel(app: harness.app)
        #expect(!viewModel.showsTouchIDButton)
        #expect(viewModel.biometricNotice == LockNoticeModel(
            title: "Password required: After a restart",
            detail: "Your Mac restarted, so FX Vault needs your master password once before Touch ID works again."
        ))
        #expect(viewModel.subtitle == "Enter your master password to unlock.")
    }

    @Test func fourteenDayReasonUnderThePasswordField() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        try await harness.enableTouchID()
        harness.app.lock(trigger: .manual)
        harness.clock.advance(by: Timeouts.passwordMaxAge + .seconds(1))
        let viewModel = LockViewModel(app: harness.app)
        #expect(viewModel.biometricNotice == LockNoticeModel(
            title: "Password required: Every 14 days",
            detail: "FX Vault asks for your master password at least every 14 days."
        ))
    }

    @Test func usableTouchIDShowsTheButtonAndNoReason() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        try await harness.enableTouchID()
        harness.app.lock(trigger: .manual)
        let viewModel = LockViewModel(app: harness.app)
        #expect(viewModel.showsTouchIDButton)
        #expect(viewModel.biometricNotice == nil)
    }

    @Test func lockoutShowsOnlyTheExplanation() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        try await harness.enableTouchID()
        harness.app.lock(trigger: .manual)
        harness.capabilities.unavailableReason = .lockout
        let viewModel = LockViewModel(app: harness.app)
        #expect(viewModel.biometricNotice == LockNoticeModel(
            title: nil,
            detail: BiometryUnavailableReason.lockout.localizedMessage
        ))
    }
}
