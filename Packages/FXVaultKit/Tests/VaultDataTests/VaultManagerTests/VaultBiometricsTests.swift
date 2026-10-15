import Foundation
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

@Suite("VaultManager Touch ID")
struct VaultBiometricsTests {
    /// A created vault with Touch ID enabled, then locked.
    private static func enabledAndLocked() async throws -> (VaultHarness, RecoveryKey) {
        let (harness, recoveryKey) = try await VaultHarness.created()
        try await harness.manager.enableBiometrics(password: VaultFixture.password)
        harness.manager.lock()
        return (harness, recoveryKey)
    }

    // MARK: - Enable and unlock

    @Test func enableStoresTheDEKAndUnlockUsesIt() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        let repo = try harness.seedRepository()
        let id = try harness.insertItem(repo: repo, name: "API_TOKEN", value: VaultFixture.secretValue)
        try await harness.manager.enableBiometrics(password: VaultFixture.password)
        harness.manager.lock()

        #expect(try harness.manager.isBiometricsEnabled())
        #expect(try harness.vaultRecord().biometryStateHash == FakeBuildCapabilities.defaultStateHash)
        #expect(harness.biometrics.accounts == [try harness.account])
        #expect(try harness.manager.biometricUnlockStatus() == .available)

        try await harness.manager.unlockWithBiometrics(prompt: VaultFixture.prompt)
        #expect(harness.manager.state == .unlocked)
        #expect(harness.biometrics.loadCount == 1)
        #expect(harness.biometrics.lastPrompt == VaultFixture.prompt)
        #expect(try harness.value(of: id) == VaultFixture.secretValue)
    }

    @Test func touchIDUnlockDoesNotCountAsAPasswordCheck() async throws {
        let (harness, recoveryKey) = try await Self.enabledAndLocked()
        defer { recoveryKey.wipe() }
        let before = try harness.vaultRecord().lastPasswordUnlockAt
        harness.clock.advance(by: .seconds(Timeouts.secondsPerDay))
        try await harness.manager.unlockWithBiometrics(prompt: VaultFixture.prompt)
        #expect(try harness.vaultRecord().lastPasswordUnlockAt == before)
    }

    @Test func enableRequiresTheMasterPasswordAndAnUnlockedVault() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        let wrong = await vaultError {
            try await harness.manager.enableBiometrics(password: VaultFixture.otherPassword)
        }
        #expect(wrong == .wrongPassword)
        #expect(harness.biometrics.accounts.isEmpty)

        harness.manager.lock()
        let locked = await vaultError {
            try await harness.manager.enableBiometrics(password: VaultFixture.password)
        }
        #expect(locked == .locked)
    }

    @Test func adHocBuildCannotEnableOrUseTouchID() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        harness.capabilities.accessGroup = nil
        #expect(harness.manager.biometricsAvailability() == .unsignedBuild)
        let enable = await vaultError {
            try await harness.manager.enableBiometrics(password: VaultFixture.password)
        }
        #expect(enable == .biometryUnavailable(.unsignedBuild))

        harness.manager.lock()
        #expect(try harness.manager.biometricUnlockStatus() == .unavailable(.unsignedBuild))
        let unlock = await vaultError {
            try await harness.manager.unlockWithBiometrics(prompt: VaultFixture.prompt)
        }
        #expect(unlock == .biometryUnavailable(.unsignedBuild))
        #expect(harness.biometrics.loadCount == 0)
    }

    @Test func unlockWithoutEnablementIsNotEnabled() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        harness.manager.lock()
        #expect(try harness.manager.biometricUnlockStatus() == .unavailable(.notEnabled))
        let error = await vaultError {
            try await harness.manager.unlockWithBiometrics(prompt: VaultFixture.prompt)
        }
        #expect(error == .biometryUnavailable(.notEnabled))
    }

    @Test func hardwareUnavailabilityIsReportedWithoutAPrompt() async throws {
        let (harness, recoveryKey) = try await Self.enabledAndLocked()
        defer { recoveryKey.wipe() }
        harness.capabilities.unavailableReason = .lockout
        harness.capabilities.stateHash = nil
        let error = await vaultError {
            try await harness.manager.unlockWithBiometrics(prompt: VaultFixture.prompt)
        }
        #expect(error == .biometryUnavailable(.lockout))
        #expect(harness.biometrics.loadCount == 0)
        #expect(try harness.manager.isBiometricsEnabled())
    }

    @Test func lockDuringThePromptWinsOverTheUnlock() async throws {
        let (harness, recoveryKey) = try await Self.enabledAndLocked()
        defer { recoveryKey.wipe() }
        let manager = harness.manager
        harness.biometrics.onNextLoad { manager.lock() }

        let error = await vaultError {
            try await harness.manager.unlockWithBiometrics(prompt: VaultFixture.prompt)
        }
        #expect(error == .locked)
        #expect(harness.manager.state == .locked)
        #expect(harness.session.isLocked)
        #expect(try harness.manager.isBiometricsEnabled())
    }

    // MARK: - Invalidation and errors

    @Test func invalidatedItemIsDeletedAndTouchIDDisabled() async throws {
        let (harness, recoveryKey) = try await Self.enabledAndLocked()
        defer { recoveryKey.wipe() }
        let account = try harness.account
        harness.biometrics.invalidateItems()

        let error = await vaultError {
            try await harness.manager.unlockWithBiometrics(prompt: VaultFixture.prompt)
        }
        #expect(error == .biometryInvalidated)
        #expect(harness.biometrics.deletedAccounts.contains(account))
        #expect(harness.biometrics.accounts.isEmpty)
        #expect(try !harness.manager.isBiometricsEnabled())
        #expect(harness.manager.state == .locked)
    }

    @Test func missingItemWhileEnabledIsInvalidated() async throws {
        let (harness, recoveryKey) = try await Self.enabledAndLocked()
        defer { recoveryKey.wipe() }
        try harness.biometrics.delete(account: harness.account)
        let error = await vaultError {
            try await harness.manager.unlockWithBiometrics(prompt: VaultFixture.prompt)
        }
        #expect(error == .biometryInvalidated)
        #expect(harness.biometrics.loadCount == 0)
        #expect(try !harness.manager.isBiometricsEnabled())
    }

    @Test func cancelLeavesTouchIDEnabled() async throws {
        let (harness, recoveryKey) = try await Self.enabledAndLocked()
        defer { recoveryKey.wipe() }
        harness.biometrics.failNextLoad(with: .cancelled)
        let error = await vaultError {
            try await harness.manager.unlockWithBiometrics(prompt: VaultFixture.prompt)
        }
        #expect(error == .cancelled)
        #expect(try harness.manager.isBiometricsEnabled())
        try await harness.manager.unlockWithBiometrics(prompt: VaultFixture.prompt)
        #expect(harness.manager.state == .unlocked)
    }

    @Test func passwordFallbackLeavesTouchIDEnabled() async throws {
        let (harness, recoveryKey) = try await Self.enabledAndLocked()
        defer { recoveryKey.wipe() }
        harness.biometrics.failNextLoad(with: .passwordFallbackRequested)
        let error = await vaultError {
            try await harness.manager.unlockWithBiometrics(prompt: VaultFixture.prompt)
        }
        #expect(error == .passwordFallbackRequested)
        #expect(harness.manager.state == .locked)
        #expect(try harness.manager.isBiometricsEnabled())
        #expect(harness.biometrics.deletedAccounts.isEmpty)
    }

    @Test func foreignItemFailsTheKeyCheckAndIsDeleted() async throws {
        let (harness, recoveryKey) = try await Self.enabledAndLocked()
        defer { recoveryKey.wipe() }
        let account = try harness.account
        harness.biometrics.replaceItem(account: account, with: Data(repeating: 0x42, count: Limits.dekBytes))

        let error = await vaultError {
            try await harness.manager.unlockWithBiometrics(prompt: VaultFixture.prompt)
        }
        #expect(error == .corrupted(.keyCheckMismatch))
        #expect(harness.biometrics.accounts.isEmpty)
        #expect(try !harness.manager.isBiometricsEnabled())
        #expect(harness.manager.state == .locked)
    }

    // MARK: - Password rules (§5.5)

    @Test func restartRequiresThePassword() async throws {
        let (harness, recoveryKey) = try await Self.enabledAndLocked()
        defer { recoveryKey.wipe() }
        harness.capabilities.bootSession = "boot-after-restart"
        #expect(try harness.manager.passwordRequirement() == .restart)
        #expect(try harness.manager.biometricUnlockStatus() == .passwordRequired(.restart))
        let error = await vaultError {
            try await harness.manager.unlockWithBiometrics(prompt: VaultFixture.prompt)
        }
        #expect(error == .passwordRequired(reason: .restart))
        #expect(harness.biometrics.loadCount == 0)
        #expect(try harness.manager.isBiometricsEnabled())

        try await harness.manager.unlock(password: VaultFixture.password)
        harness.manager.lock()
        try await harness.manager.unlockWithBiometrics(prompt: VaultFixture.prompt)
        #expect(harness.manager.state == .unlocked)
    }

    @Test func unreadableBootSessionCountsAsARestart() async throws {
        let (harness, recoveryKey) = try await Self.enabledAndLocked()
        defer { recoveryKey.wipe() }
        harness.capabilities.bootSession = nil
        #expect(try harness.manager.passwordRequirement() == .restart)
    }

    @Test func fourteenDayRule() async throws {
        let (harness, recoveryKey) = try await Self.enabledAndLocked()
        defer { recoveryKey.wipe() }
        harness.clock.advance(by: VaultFixture.fourteenDays)
        #expect(try harness.manager.passwordRequirement() == nil)
        try await harness.manager.unlockWithBiometrics(prompt: VaultFixture.prompt)
        harness.manager.lock()

        harness.clock.advance(by: VaultFixture.oneSecond)
        #expect(try harness.manager.passwordRequirement() == .periodic)
        let error = await vaultError {
            try await harness.manager.unlockWithBiometrics(prompt: VaultFixture.prompt)
        }
        #expect(error == .passwordRequired(reason: .periodic))

        try await harness.manager.unlock(password: VaultFixture.password)
        harness.manager.lock()
        #expect(try harness.manager.passwordRequirement() == nil)
        try await harness.manager.unlockWithBiometrics(prompt: VaultFixture.prompt)
    }

    @Test func clockMovedBeforeTheLastPasswordCheckRequiresThePassword() async throws {
        let (harness, recoveryKey) = try await Self.enabledAndLocked()
        defer { recoveryKey.wipe() }
        harness.clock.setWallClock(to: ManualClock.defaultStart.addingTimeInterval(-VaultFixture.oneSecond.timeInterval))
        #expect(try harness.manager.passwordRequirement() == .periodic)
    }

    @Test func enrollmentChangeRequiresThePasswordAndDeletesTheItem() async throws {
        let (harness, recoveryKey) = try await Self.enabledAndLocked()
        defer { recoveryKey.wipe() }
        harness.capabilities.stateHash = Data("enrollment-b".utf8)
        #expect(try harness.manager.biometricUnlockStatus() == .passwordRequired(.biometryChanged))

        let error = await vaultError {
            try await harness.manager.unlockWithBiometrics(prompt: VaultFixture.prompt)
        }
        #expect(error == .passwordRequired(reason: .biometryChanged))
        #expect(harness.biometrics.loadCount == 0)
        #expect(harness.biometrics.accounts.isEmpty)
        #expect(try !harness.manager.isBiometricsEnabled())

        // Re-enabling after a password unlock records the new enrollment.
        try await harness.manager.unlock(password: VaultFixture.password)
        try await harness.manager.enableBiometrics(password: VaultFixture.password)
        #expect(try harness.vaultRecord().biometryStateHash == Data("enrollment-b".utf8))
    }

    @Test func passwordUnlockAfterAnEnrollmentChangeTurnsTouchIDOff() async throws {
        let (harness, recoveryKey) = try await Self.enabledAndLocked()
        defer { recoveryKey.wipe() }
        harness.capabilities.stateHash = Data("enrollment-b".utf8)
        #expect(try harness.manager.biometricUnlockStatus() == .passwordRequired(.biometryChanged))

        // The lock screen never prompts in this state; the password unlock drops the dead item.
        try await harness.manager.unlock(password: VaultFixture.password)
        #expect(harness.biometrics.loadCount == 0)
        #expect(harness.biometrics.accounts.isEmpty)
        #expect(try !harness.manager.isBiometricsEnabled())
        harness.manager.lock()
        #expect(try harness.manager.biometricUnlockStatus() == .unavailable(.notEnabled))
    }

    @Test(arguments: [false, true])
    func passwordUnlockRecordsTheTurnOffWhateverReasonTheLockScreenShowed(afterRestart: Bool) async throws {
        let (harness, recoveryKey) = try await Self.enabledAndLocked()
        defer { recoveryKey.wipe() }
        #expect(!harness.manager.isBiometricsTurnedOffAutomatically)
        harness.capabilities.stateHash = Data("enrollment-b".utf8)
        if afterRestart {
            // The restart rule is checked before the enrollment, so the lock screen says
            // "After a restart", not "Fingerprints changed".
            harness.capabilities.bootSession = "boot-after-restart"
            #expect(try harness.manager.biometricUnlockStatus() == .passwordRequired(.restart))
        } else {
            harness.clock.advance(by: Timeouts.passwordMaxAge + VaultFixture.oneSecond)
            #expect(try harness.manager.biometricUnlockStatus() == .passwordRequired(.periodic))
        }

        try await harness.manager.unlock(password: VaultFixture.password)
        #expect(try !harness.manager.isBiometricsEnabled())
        #expect(harness.manager.isBiometricsTurnedOffAutomatically)

        harness.manager.acknowledgeBiometricsTurnedOff()
        #expect(!harness.manager.isBiometricsTurnedOffAutomatically)
    }

    @Test func reauthAfterAnEnrollmentChangeRecordsTheTurnOff() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        try await harness.manager.enableBiometrics(password: VaultFixture.password)
        harness.capabilities.stateHash = Data("enrollment-b".utf8)

        let error = await vaultError {
            try await harness.manager.reauthenticate(prompt: VaultFixture.prompt)
        }
        #expect(error == .passwordRequired(reason: .biometryChanged))
        #expect(try !harness.manager.isBiometricsEnabled())
        // Survives the lock, so the next password unlock can offer Touch ID again.
        harness.manager.lock()
        try await harness.manager.unlock(password: VaultFixture.password)
        #expect(harness.manager.isBiometricsTurnedOffAutomatically)

        // Enabling again settles it.
        try await harness.manager.enableBiometrics(password: VaultFixture.password)
        #expect(!harness.manager.isBiometricsTurnedOffAutomatically)
    }

    @Test func turningTouchIDOffOnPurposeIsNotAnAutomaticTurnOff() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        try await harness.manager.enableBiometrics(password: VaultFixture.password)
        try await harness.manager.disableBiometrics(password: VaultFixture.password)
        #expect(!harness.manager.isBiometricsTurnedOffAutomatically)
    }

    @Test func passwordUnlockKeepsTouchIDWhenTheEnrollmentIsUnchangedOrUnknown() async throws {
        let (harness, recoveryKey) = try await Self.enabledAndLocked()
        defer { recoveryKey.wipe() }
        try await harness.manager.unlock(password: VaultFixture.password)
        #expect(try harness.manager.isBiometricsEnabled())
        harness.manager.lock()

        // Touch ID unavailable right now (lid closed): no state hash, nothing is decided.
        harness.capabilities.stateHash = nil
        try await harness.manager.unlock(password: VaultFixture.password)
        #expect(try harness.manager.isBiometricsEnabled())
        #expect(harness.biometrics.accounts == [try harness.account])
    }

    // MARK: - Orphans, disable, rotation

    @Test func enableDeletesOrphanedItemsOfOtherVaults() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        let orphanA = BiometricKeyAccount.name(vaultID: Data(repeating: 0x01, count: Limits.vaultIDBytes))
        let orphanB = "legacy-account"
        harness.biometrics.seedItem(account: orphanA, bytes: Data(repeating: 0x11, count: Limits.dekBytes))
        harness.biometrics.seedItem(account: orphanB, bytes: Data(repeating: 0x22, count: Limits.dekBytes))

        try await harness.manager.enableBiometrics(password: VaultFixture.password)
        #expect(harness.biometrics.accounts == [try harness.account])
        #expect(Set(harness.biometrics.deletedAccounts).isSuperset(of: [orphanA, orphanB]))
    }

    @Test func disableRequiresThePasswordAndDeletesTheItem() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        try await harness.manager.enableBiometrics(password: VaultFixture.password)

        let wrong = await vaultError {
            try await harness.manager.disableBiometrics(password: VaultFixture.otherPassword)
        }
        #expect(wrong == .wrongPassword)
        #expect(try harness.manager.isBiometricsEnabled())

        try await harness.manager.disableBiometrics(password: VaultFixture.password)
        #expect(try !harness.manager.isBiometricsEnabled())
        #expect(harness.biometrics.accounts.isEmpty)
        harness.manager.lock()
        #expect(try harness.manager.biometricUnlockStatus() == .unavailable(.notEnabled))
    }

    @Test func rotationReplacesTheTouchIDItem() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        try await harness.manager.enableBiometrics(password: VaultFixture.password)
        let account = try harness.account
        let oldItem = harness.biometrics.storedBytes(account: account)

        let newRecovery = try await harness.manager.rotateDEK(password: VaultFixture.password)
        newRecovery.wipe()
        let newItem = harness.biometrics.storedBytes(account: account)
        #expect(newItem != nil)
        #expect(newItem != oldItem)

        harness.manager.lock()
        try await harness.manager.unlockWithBiometrics(prompt: VaultFixture.prompt)
        #expect(harness.manager.state == .unlocked)
    }

    @Test func failedItemReplacementDisablesTouchID() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        try await harness.manager.enableBiometrics(password: VaultFixture.password)
        harness.biometrics.failStores(with: .biometryUnavailable(.notAvailable))

        let newRecovery = try await harness.manager.rotateDEK(password: VaultFixture.password)
        newRecovery.wipe()
        #expect(try !harness.manager.isBiometricsEnabled())
        #expect(harness.biometrics.accounts.isEmpty)
    }
}
