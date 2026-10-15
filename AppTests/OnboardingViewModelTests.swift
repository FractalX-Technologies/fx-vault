import AppKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

@MainActor
@Suite("OnboardingViewModel")
struct OnboardingViewModelTests {
    /// Always asks for groups 3 and 12 (1-based 4 and 13).
    private static let fixedPicker: OnboardingViewModel.GroupPicker = { _, _ in [3, 12] }

    private func makeViewModel(signed: Bool = true) async throws -> (TestHarness, OnboardingViewModel) {
        let harness = try await TestHarness(vault: .none, signed: signed, ghStatus: .notInstalled)
        let viewModel = OnboardingViewModel(app: harness.app, groupPicker: Self.fixedPicker)
        return (harness, viewModel)
    }

    @Test func startsAtWelcomeWithGHStatus() async throws {
        let (harness, viewModel) = try await makeViewModel()
        await harness.app.refreshGHStatus()
        #expect(viewModel.step == .welcome)
        #expect(viewModel.ghStatus == .notInstalled)
        #expect(harness.app.phase == .onboarding)
        viewModel.start()
        #expect(viewModel.step == .createPassword)
    }

    @Test func weakOrMismatchedPasswordCannotCreate() async throws {
        let (_, viewModel) = try await makeViewModel()
        viewModel.start()
        viewModel.password = "password1234"
        viewModel.passwordConfirmation = "password1234"
        #expect(!viewModel.strength.isAcceptable)
        #expect(!viewModel.canCreateVault)
        #expect(viewModel.strength.primaryHint != nil)

        viewModel.password = testPassword
        viewModel.passwordConfirmation = otherTestPassword
        #expect(viewModel.showsMismatch)
        #expect(!viewModel.canCreateVault)

        viewModel.passwordConfirmation = testPassword
        #expect(viewModel.canCreateVault)
    }

    @Test func generatedPassphraseIsAcceptableSixWords() async throws {
        let (_, viewModel) = try await makeViewModel()
        viewModel.start()
        #expect(viewModel.canGeneratePassphrase)
        viewModel.generatePassphrase()
        let passphrase = try #require(viewModel.generatedPassphrase)
        #expect(passphrase.split(separator: "-").count == Limits.passphraseWordCount)
        #expect(viewModel.password == passphrase)
        #expect(viewModel.passwordConfirmation == passphrase)
        #expect(viewModel.strength.isAcceptable)
        #expect(viewModel.canCreateVault)

        viewModel.password += "x"
        #expect(viewModel.generatedPassphrase == nil)
    }

    @Test func copyingThePassphraseUsesTheClipboardManager() async throws {
        let (harness, viewModel) = try await makeViewModel()
        viewModel.generatePassphrase()
        viewModel.copyGeneratedPassphrase()
        #expect(harness.pasteboardString == viewModel.generatedPassphrase)
        #expect(harness.pasteboard.types?.contains(ClipboardManager.Marker.concealed) == true)
    }

    @Test func fullSignedFlowEnablesTouchIDAndUnlocks() async throws {
        let (harness, viewModel) = try await makeViewModel(signed: true)
        #expect(viewModel.includesTouchIDStep)
        #expect(viewModel.visibleSteps.contains(.touchID))
        viewModel.start()
        viewModel.password = testPassword
        viewModel.passwordConfirmation = testPassword
        await viewModel.createVault()

        #expect(viewModel.error == nil)
        #expect(viewModel.step == .recoveryKey)
        #expect(viewModel.recoveryKeyGroups.count == Limits.recoveryKeyGroupCount)
        #expect(harness.vaultManager.state == .unlocked)
        #expect(harness.app.phase == .onboarding)
        #expect(harness.preferences.isRecoveryKeyConfirmationPending)

        viewModel.copyRecoveryKey()
        #expect(viewModel.hasCopiedRecoveryKey)
        #expect(harness.pasteboardString == viewModel.recoveryKeyGroups.joined(separator: "-"))

        let groups = viewModel.recoveryKeyGroups
        viewModel.continueToConfirmation()
        #expect(viewModel.step == .confirmRecoveryKey)
        #expect(viewModel.confirmationIndices == [3, 12])

        viewModel.confirmationInputs = [groups[3], groups[3]]
        viewModel.confirmRecoveryKey()
        #expect(viewModel.confirmationFailed)
        #expect(viewModel.step == .confirmRecoveryKey)

        viewModel.confirmationInputs = [groups[3].lowercased(), groups[12]]
        viewModel.confirmRecoveryKey()
        #expect(!viewModel.confirmationFailed)
        #expect(viewModel.step == .touchID)
        #expect(viewModel.recoveryKeyGroups.isEmpty)
        #expect(!harness.preferences.isRecoveryKeyConfirmationPending)

        await viewModel.enableTouchID()
        #expect(viewModel.error == nil)
        #expect(viewModel.isTouchIDEnabled)
        #expect(viewModel.step == .done)
        #expect(viewModel.password.isEmpty)
        #expect(try harness.vaultManager.isBiometricsEnabled())
        #expect(!harness.biometrics.accounts.isEmpty)

        viewModel.finish()
        #expect(harness.app.phase == .unlocked)
    }

    @Test func unsignedBuildSkipsTouchIDStep() async throws {
        let (harness, viewModel) = try await makeViewModel(signed: false)
        #expect(!viewModel.includesTouchIDStep)
        #expect(!viewModel.visibleSteps.contains(.touchID))
        viewModel.start()
        viewModel.password = testPassword
        viewModel.passwordConfirmation = testPassword
        await viewModel.createVault()
        let groups = viewModel.recoveryKeyGroups
        viewModel.continueToConfirmation()
        viewModel.confirmationInputs = [groups[3], groups[12]]
        viewModel.confirmRecoveryKey()
        #expect(viewModel.step == .done)
        #expect(viewModel.password.isEmpty)
        #expect(harness.biometrics.accounts.isEmpty)
    }

    @Test func skippingTouchIDLeavesItOff() async throws {
        let (harness, viewModel) = try await makeViewModel(signed: true)
        viewModel.start()
        viewModel.password = testPassword
        viewModel.passwordConfirmation = testPassword
        await viewModel.createVault()
        let groups = viewModel.recoveryKeyGroups
        viewModel.continueToConfirmation()
        viewModel.confirmationInputs = [groups[3], groups[12]]
        viewModel.confirmRecoveryKey()
        viewModel.skipTouchID()
        #expect(viewModel.step == .done)
        #expect(try !harness.vaultManager.isBiometricsEnabled())
    }

    @Test func lockDuringRecoveryKeyStepWipesKeyAndKeepsReminder() async throws {
        let (harness, viewModel) = try await makeViewModel()
        viewModel.start()
        viewModel.password = testPassword
        viewModel.passwordConfirmation = testPassword
        await viewModel.createVault()
        #expect(viewModel.step == .recoveryKey)

        harness.signals.send(.systemSleep)

        #expect(harness.vaultManager.state == .locked)
        #expect(harness.app.phase == .locked)
        #expect(viewModel.recoveryKeyGroups.isEmpty)
        #expect(viewModel.password.isEmpty)
        #expect(viewModel.step == .welcome)
        #expect(harness.preferences.isRecoveryKeyConfirmationPending)
    }

    @Test func randomPickerChoosesDistinctSortedGroups() {
        for _ in 0..<50 {
            let picked = OnboardingViewModel.randomGroupPicker(Limits.recoveryKeyGroupCount, Limits.recoveryConfirmGroupCount)
            #expect(picked.count == Limits.recoveryConfirmGroupCount)
            #expect(Set(picked).count == picked.count)
            #expect(picked == picked.sorted())
            #expect(picked.allSatisfy { (0..<Limits.recoveryKeyGroupCount).contains($0) })
        }
    }
}
