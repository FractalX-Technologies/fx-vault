import SwiftUI
import VaultCore

/// Welcome: what FX Vault is, plus the gh status row.
struct WelcomeStepView: View {
    let viewModel: OnboardingViewModel

    var body: some View {
        CardHeader(
            systemImage: "lock.shield",
            title: String(localized: "onboarding.welcome.title", defaultValue: "Welcome to FX Vault"),
            subtitle: String(
                localized: "onboarding.welcome.subtitle",
                defaultValue: "Keep your GitHub Actions secrets and variables in an encrypted vault on this Mac, and sync them to GitHub through the GitHub CLI."
            )
        )
        GHStatusRow(status: viewModel.ghStatus)
        HStack {
            Spacer()
            Button(String(localized: "onboarding.welcome.start", defaultValue: "Create Vault")) {
                viewModel.start()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// Create password: ≥ 12 characters and ≥ 60 bits, a generated passphrase, confirmation (D8).
struct CreatePasswordStepView: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        CardHeader(
            systemImage: "key",
            title: String(localized: "onboarding.password.title", defaultValue: "Choose a master password"),
            subtitle: String(
                localized: "onboarding.password.subtitle",
                defaultValue: "It encrypts everything in your vault. FX Vault cannot recover it for you; your recovery key is the only way back in."
            )
        )
        NewPasswordFields(
            password: $viewModel.password,
            confirmation: $viewModel.passwordConfirmation,
            strength: viewModel.strength,
            showsMismatch: viewModel.showsMismatch
        ) {
            Task { await viewModel.createVault() }
        }
        .disabled(viewModel.isWorking)

        if let passphrase = viewModel.generatedPassphrase {
            PassphraseView(passphrase: passphrase) {
                viewModel.copyGeneratedPassphrase()
            }
        }

        HStack {
            if viewModel.canGeneratePassphrase {
                Button(String(localized: "onboarding.password.generate", defaultValue: "Generate Passphrase")) {
                    viewModel.generatePassphrase()
                }
                .disabled(viewModel.isWorking)
            }
            Spacer()
            if viewModel.isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            Button(String(localized: "onboarding.password.create", defaultValue: "Continue")) {
                Task { await viewModel.createVault() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canCreateVault)
        }
    }
}

/// Recovery key: the grid, Copy, and the warning (§5.3).
struct RecoveryKeyStepView: View {
    let viewModel: OnboardingViewModel

    var body: some View {
        CardHeader(
            systemImage: "key.viewfinder",
            title: String(localized: "onboarding.recovery.title", defaultValue: "Save your recovery key"),
            subtitle: String(
                localized: "onboarding.recovery.subtitle",
                defaultValue: "If you forget your master password, this key is the only way to open your vault. Store it in a password manager. FX Vault never stores it and will not show it again."
            )
        )
        RecoveryKeyGridView(groups: viewModel.recoveryKeyGroups)
        Label(
            String(
                localized: "onboarding.recovery.warning",
                defaultValue: "Anyone with this key can reset your master password."
            ),
            systemImage: "exclamationmark.triangle"
        )
        .font(Theme.Typography.callout)
        .foregroundStyle(Theme.Colors.warning)
        HStack {
            Button(String(localized: "onboarding.recovery.copy", defaultValue: "Copy")) {
                viewModel.copyRecoveryKey()
            }
            if viewModel.hasCopiedRecoveryKey {
                Text(String(
                    localized: "onboarding.recovery.copied",
                    defaultValue: "Copied. The clipboard clears in \(Timeouts.clipboardClear.wholeSeconds) seconds."
                ))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer()
            Button(String(localized: "onboarding.recovery.saved", defaultValue: "I Saved It")) {
                viewModel.continueToConfirmation()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// Confirm 2 randomly chosen groups (§5.3).
struct ConfirmRecoveryKeyStepView: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        CardHeader(
            systemImage: "checkmark.shield",
            title: String(localized: "onboarding.confirm.title", defaultValue: "Confirm your recovery key"),
            subtitle: String(
                localized: "onboarding.confirm.subtitle",
                defaultValue: "Enter the requested groups from the key you saved."
            )
        )
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            ForEach(Array(viewModel.confirmationIndices.enumerated()), id: \.offset) { position, groupIndex in
                if viewModel.confirmationInputs.indices.contains(position) {
                    let label = String(localized: "onboarding.confirm.group", defaultValue: "Group \(groupIndex + 1)")
                    LabeledContent(label) {
                        TextField(label, text: $viewModel.confirmationInputs[position])
                            .labelsHidden()
                            .font(Theme.Typography.monospaced)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: Theme.Layout.recoveryGroupFieldWidth)
                            .autocorrectionDisabled()
                            .onSubmit { viewModel.confirmRecoveryKey() }
                    }
                }
            }
        }
        if viewModel.confirmationFailed {
            Text(String(
                localized: "onboarding.confirm.mismatch",
                defaultValue: "That does not match your recovery key. Check the groups or go back to the key."
            ))
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.danger)
        }
        HStack {
            Button(String(localized: "onboarding.confirm.back", defaultValue: "Show Key Again")) {
                viewModel.backToRecoveryKey()
            }
            Spacer()
            Button(String(localized: "onboarding.confirm.continue", defaultValue: "Confirm")) {
                viewModel.confirmRecoveryKey()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canConfirmRecoveryKey)
        }
    }
}

/// Touch ID (signed builds only, D14).
struct TouchIDStepView: View {
    let viewModel: OnboardingViewModel

    var body: some View {
        CardHeader(
            systemImage: "touchid",
            title: String(localized: "onboarding.touchID.title", defaultValue: "Unlock with Touch ID"),
            subtitle: String(
                localized: "onboarding.touchID.subtitle",
                defaultValue: "Use your fingerprint instead of typing the master password. FX Vault still asks for the password after a restart and at least every \(Timeouts.passwordMaxAge.wholeDays) days."
            )
        )
        if let reason = viewModel.touchIDUnavailableReason {
            Text(reason.localizedMessage)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        HStack {
            Button(String(localized: "onboarding.touchID.skip", defaultValue: "Not Now")) {
                viewModel.skipTouchID()
            }
            Spacer()
            if viewModel.isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            Button(String(localized: "onboarding.touchID.enable", defaultValue: "Turn On Touch ID")) {
                Task { await viewModel.enableTouchID() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canEnableTouchID)
        }
    }
}

/// Done.
struct DoneStepView: View {
    let viewModel: OnboardingViewModel

    var body: some View {
        CardHeader(
            systemImage: "checkmark.circle",
            title: String(localized: "onboarding.done.title", defaultValue: "Your vault is ready"),
            subtitle: viewModel.isTouchIDEnabled
                ? String(
                    localized: "onboarding.done.subtitleTouchID",
                    defaultValue: "Touch ID is on. FX Vault locks when your Mac sleeps, the screen locks, the window closes, or after a few idle minutes."
                )
                : String(
                    localized: "onboarding.done.subtitle",
                    defaultValue: "FX Vault locks when your Mac sleeps, the screen locks, the window closes, or after a few idle minutes."
                )
        )
        HStack {
            Spacer()
            Button(String(localized: "onboarding.done.open", defaultValue: "Open FX Vault")) {
                viewModel.finish()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}
