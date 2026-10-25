import Foundation
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

@Suite("ReauthGate")
struct ReauthGateTests {
    private static func enabledHarness() async throws -> (VaultHarness, RecoveryKey) {
        let (harness, recoveryKey) = try await VaultHarness.created()
        try await harness.manager.enableBiometrics(password: VaultFixture.password)
        return (harness, recoveryKey)
    }

    @Test(arguments: ReauthPurpose.allCases)
    func touchIDAuthorizesExportAndShare(purpose: ReauthPurpose) async throws {
        let (harness, recoveryKey) = try await Self.enabledHarness()
        defer { recoveryKey.wipe() }
        try await harness.manager.reauthGate.authorize(purpose, with: .biometrics(VaultFixture.prompt))
        #expect(harness.biometrics.loadCount == 1)
        #expect(harness.manager.state == .unlocked)
    }

    @Test(arguments: ReauthPurpose.allCases)
    func passwordAuthorizesExportAndShare(purpose: ReauthPurpose) async throws {
        let (harness, recoveryKey) = try await Self.enabledHarness()
        defer { recoveryKey.wipe() }
        try await harness.manager.reauthGate.authorize(purpose, with: .password(VaultFixture.password))
        #expect(harness.biometrics.loadCount == 0)

        let error = await vaultError {
            try await harness.manager.reauthGate.authorize(purpose, with: .password(VaultFixture.otherPassword))
        }
        #expect(error == .wrongPassword)
    }

    @Test(arguments: PasswordReauthPurpose.allCases)
    func passwordOnlyOperationsNeverReadTheTouchIDItem(purpose: PasswordReauthPurpose) async throws {
        let (harness, recoveryKey) = try await Self.enabledHarness()
        defer { recoveryKey.wipe() }
        try await harness.manager.reauthGate.authorizeWithPassword(purpose, password: VaultFixture.password)
        let error = await vaultError {
            try await harness.manager.reauthGate.authorizeWithPassword(purpose, password: VaultFixture.otherPassword)
        }
        #expect(error == .wrongPassword)
        #expect(harness.biometrics.loadCount == 0)
    }

    /// The password-only operations of VaultManager take the password and never prompt, even with
    /// Touch ID enabled and available.
    @Test func passwordOnlyManagerOperationsNeverPrompt() async throws {
        let (harness, recoveryKey) = try await Self.enabledHarness()
        defer { recoveryKey.wipe() }
        let recovery = try await harness.manager.newRecoveryKey(password: VaultFixture.password)
        recovery.wipe()
        let rotated = try await harness.manager.rotateDEK(password: VaultFixture.password)
        rotated.wipe()
        _ = try await harness.manager.changePassword(
            current: VaultFixture.password,
            new: VaultFixture.otherPassword,
            rotate: false
        )
        try await harness.manager.disableBiometrics(password: VaultFixture.otherPassword)
        try await harness.manager.resetVault(password: VaultFixture.otherPassword)
        #expect(harness.biometrics.loadCount == 0)
    }

    @Test func gateRequiresAnUnlockedVault() async throws {
        let (harness, recoveryKey) = try await Self.enabledHarness()
        defer { recoveryKey.wipe() }
        harness.manager.lock()
        let touchID = await vaultError {
            try await harness.manager.reauthGate.authorize(.export, with: .biometrics(VaultFixture.prompt))
        }
        #expect(touchID == .locked)
        let password = await vaultError {
            try await harness.manager.reauthGate.authorizeWithPassword(.rotateKey, password: VaultFixture.password)
        }
        #expect(password == .locked)
        #expect(harness.biometrics.loadCount == 0)
    }

    @Test func touchIDReauthObeysThePasswordRules() async throws {
        let (harness, recoveryKey) = try await Self.enabledHarness()
        defer { recoveryKey.wipe() }
        harness.capabilities.bootSession = "boot-after-restart"
        let error = await vaultError {
            try await harness.manager.reauthGate.authorize(.share, with: .biometrics(VaultFixture.prompt))
        }
        #expect(error == .passwordRequired(reason: .restart))
        try await harness.manager.reauthGate.authorize(.share, with: .password(VaultFixture.password))
        try await harness.manager.reauthGate.authorize(.share, with: .biometrics(VaultFixture.prompt))
    }

    @Test func touchIDReauthFailsWhenTheItemIsForeign() async throws {
        let (harness, recoveryKey) = try await Self.enabledHarness()
        defer { recoveryKey.wipe() }
        try harness.biometrics.replaceItem(account: harness.account, with: Data(repeating: 0x42, count: Limits.dekBytes))
        let error = await vaultError {
            try await harness.manager.reauthGate.authorize(.share, with: .biometrics(VaultFixture.prompt))
        }
        #expect(error == .corrupted(.keyCheckMismatch))
        #expect(harness.manager.state == .unlocked)
    }

    @Test func touchIDReauthWithoutEnablementIsUnavailable() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        let error = await vaultError {
            try await harness.manager.reauthGate.authorize(.export, with: .biometrics(VaultFixture.prompt))
        }
        #expect(error == .biometryUnavailable(.notEnabled))
    }
}
