import Testing
import VaultCore
import VaultCrypto
import VaultData
@testable import FXVault

@MainActor
@Suite("RecoveryResetViewModel")
struct RecoveryResetViewModelTests {
    @Test func invalidKeyIsRejected() async throws {
        let harness = try await TestHarness(vault: .locked)
        let viewModel = RecoveryResetViewModel(app: harness.app)
        viewModel.recoveryKeyText = "NOT-A-KEY"
        viewModel.newPassword = otherTestPassword
        viewModel.passwordConfirmation = otherTestPassword
        #expect(viewModel.canReset)
        await viewModel.reset()
        #expect(viewModel.error == VaultError.invalidRecoveryKey.presentation)
        #expect(viewModel.step == .enterKey)
        #expect(harness.vaultManager.state == .locked)
    }

    @Test func resetRotatesAndShowsNewKey() async throws {
        let harness = try await TestHarness(vault: .locked)
        let oldKey = try #require(harness.recoveryKey)
        let oldKeyText = oldKey.formatted
        let viewModel = RecoveryResetViewModel(app: harness.app)
        viewModel.recoveryKeyText = oldKeyText.lowercased()
        viewModel.newPassword = otherTestPassword
        viewModel.passwordConfirmation = otherTestPassword
        await viewModel.reset()

        #expect(viewModel.error == nil)
        #expect(viewModel.step == .showNewKey)
        #expect(viewModel.newRecoveryKeyGroups.count == Limits.recoveryKeyGroupCount)
        #expect(viewModel.newRecoveryKeyGroups.joined(separator: "-") != oldKeyText)
        #expect(viewModel.recoveryKeyText.isEmpty)
        #expect(viewModel.newPassword.isEmpty)
        #expect(harness.preferences.isRecoveryKeyConfirmationPending)
        // Unlocked underneath, but the phase waits until the new key is saved.
        #expect(harness.vaultManager.state == .unlocked)
        #expect(harness.app.phase == .locked)

        viewModel.copyNewRecoveryKey()
        #expect(harness.pasteboardString == viewModel.newRecoveryKeyGroups.joined(separator: "-"))

        #expect(!viewModel.canFinish)
        viewModel.hasSavedNewKey = true
        viewModel.finish()
        #expect(harness.app.phase == .unlocked)
        #expect(viewModel.newRecoveryKeyGroups.isEmpty)
        #expect(!harness.preferences.isRecoveryKeyConfirmationPending)

        // The old password and the old recovery key no longer work.
        harness.app.lock(trigger: .manual)
        await #expect(throws: VaultError.wrongPassword) {
            try await harness.vaultManager.unlock(password: testPassword)
        }
        let staleKey = try RecoveryKey(parsing: oldKeyText)
        await #expect(throws: VaultError.invalidRecoveryKey) {
            _ = try await harness.vaultManager.resetWithRecoveryKey(staleKey, newPassword: testPassword)
        }
        staleKey.wipe()
        try await harness.vaultManager.unlock(password: otherTestPassword)
    }

    @Test func weakNewPasswordCannotReset() async throws {
        let harness = try await TestHarness(vault: .locked)
        let viewModel = RecoveryResetViewModel(app: harness.app)
        viewModel.recoveryKeyText = try #require(harness.recoveryKey).formatted
        viewModel.newPassword = "short"
        viewModel.passwordConfirmation = "short"
        #expect(!viewModel.canReset)
    }

    @Test func lockWhileShowingNewKeyWipesIt() async throws {
        let harness = try await TestHarness(vault: .locked)
        let lockViewModel = LockViewModel(app: harness.app)
        lockViewModel.showRecoveryReset()
        let viewModel = RecoveryResetViewModel(app: harness.app)
        viewModel.recoveryKeyText = try #require(harness.recoveryKey).formatted
        viewModel.newPassword = otherTestPassword
        viewModel.passwordConfirmation = otherTestPassword
        await viewModel.reset()
        #expect(viewModel.step == .showNewKey)

        harness.signals.send(.screenLocked)

        #expect(harness.vaultManager.state == .locked)
        #expect(viewModel.newRecoveryKeyGroups.isEmpty)
        #expect(viewModel.step == .enterKey)
        #expect(!lockViewModel.isShowingRecoveryReset)
        // The user never confirmed saving the new key: the main window reminds them.
        #expect(harness.preferences.isRecoveryKeyConfirmationPending)
    }
}
