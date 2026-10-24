import SwiftUI
import VaultCore

/// The layout of one onboarding step (board Onboarding): large title and muted paragraph, the
/// step's content in the 460 pt text column, the error, and the footer pills pinned to the
/// bottom of the column.
private struct OnboardingStepLayout<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    let error: ErrorPresentationModel?
    var isWorking = false
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLargePlus) {
            VStack(alignment: .leading, spacing: Theme.Spacing.mediumMinus) {
                Text(title)
                    .fxTextStyle(.largeTitle)
                    .foregroundStyle(Theme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .fxTextStyle(.lead)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.Layout.onboardingTextWidth, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                content()
                if let error {
                    InlineErrorView(error: error)
                }
            }
            .frame(maxWidth: Theme.Layout.onboardingTextWidth, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: Theme.Spacing.mediumMinus) {
                footer()
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, Theme.Spacing.xSmall)
                }
            }
        }
    }
}

extension OnboardingStepLayout where Content == EmptyView {
    init(title: String, subtitle: String, error: ErrorPresentationModel?, @ViewBuilder footer: @escaping () -> Footer) {
        self.init(title: title, subtitle: subtitle, error: error, content: { EmptyView() }, footer: footer)
    }
}

/// Welcome: what FX Vault is, plus the gh status row.
struct WelcomeStepView: View {
    let viewModel: OnboardingViewModel

    var body: some View {
        OnboardingStepLayout(
            title: String(localized: "onboarding.welcome.title", defaultValue: "Welcome to FX Vault"),
            subtitle: String(
                localized: "onboarding.welcome.subtitle",
                defaultValue: "Keep your GitHub Actions secrets and variables in an encrypted vault on this Mac, and sync them to GitHub through the GitHub CLI."
            ),
            error: viewModel.error
        ) {
            if viewModel.ghStatus != .unknown {
                VStack(alignment: .leading, spacing: Theme.Spacing.mediumMinus) {
                    SectionLabel(String(localized: "onboarding.welcome.gh.label", defaultValue: "GitHub CLI"))
                    GHStatusRow(status: viewModel.ghStatus)
                }
            }
        } footer: {
            Button {
                viewModel.start()
            } label: {
                ShellForwardLabel(title: String(localized: "onboarding.welcome.start", defaultValue: "Create Vault"))
            }
            .fxButtonStyle(.primary, size: .large)
            .accessibilityIdentifier(AccessibilityID.Onboarding.createVault)
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// Create password: ≥ 12 characters and ≥ 60 bits, a generated passphrase, confirmation (D8).
struct CreatePasswordStepView: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        OnboardingStepLayout(
            title: String(localized: "onboarding.password.title", defaultValue: "Choose a master password"),
            subtitle: String(
                localized: "onboarding.password.subtitle",
                defaultValue: "It encrypts everything in your vault. FX Vault cannot recover it for you; your recovery key is the only way back in."
            ),
            error: viewModel.error,
            isWorking: viewModel.isWorking
        ) {
            NewPasswordFields(
                password: $viewModel.password,
                confirmation: $viewModel.passwordConfirmation,
                strength: viewModel.strength,
                showsMismatch: viewModel.showsMismatch
            ) {
                Task { await viewModel.createVault() }
            }
            .disabled(viewModel.isWorking)

            if viewModel.canGeneratePassphrase {
                Button(String(localized: "onboarding.password.generate", defaultValue: "Generate Passphrase")) {
                    viewModel.generatePassphrase()
                }
                .fxLinkButtonStyle()
                .disabled(viewModel.isWorking)
            }

            if let passphrase = viewModel.generatedPassphrase {
                PassphraseView(passphrase: passphrase) {
                    viewModel.copyGeneratedPassphrase()
                }
            }
        } footer: {
            Button {
                Task { await viewModel.createVault() }
            } label: {
                ShellForwardLabel(title: String(localized: "onboarding.password.create", defaultValue: "Continue"))
            }
            .fxButtonStyle(.primary, size: .large)
            .accessibilityIdentifier(AccessibilityID.Onboarding.passwordContinue)
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canCreateVault)
        }
    }
}

/// Recovery key: the grid, Copy, and the warning (§5.3).
struct RecoveryKeyStepView: View {
    let viewModel: OnboardingViewModel

    var body: some View {
        OnboardingStepLayout(
            title: String(localized: "onboarding.recovery.title", defaultValue: "Save your recovery key"),
            subtitle: String(
                localized: "onboarding.recovery.subtitle",
                defaultValue: "If you forget your master password, this key is the only way to open your vault. Store it in a password manager. FX Vault never stores it and will not show it again."
            ),
            error: viewModel.error
        ) {
            RecoveryKeyGridView(groups: viewModel.recoveryKeyGroups)
            Banner(
                .warning,
                message: String(
                    localized: "onboarding.recovery.warning",
                    defaultValue: "Anyone with this key can reset your master password."
                )
            )
            HStack(spacing: Theme.Spacing.medium) {
                Button(String(localized: "onboarding.recovery.copy", defaultValue: "Copy")) {
                    viewModel.copyRecoveryKey()
                }
                .fxButtonStyle(.outline)
                if viewModel.hasCopiedRecoveryKey {
                    Text(String(
                        localized: "onboarding.recovery.copied",
                        defaultValue: "Copied. The clipboard clears in \(Timeouts.clipboardClear.wholeSeconds) seconds."
                    ))
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                }
            }
        } footer: {
            Button {
                viewModel.continueToConfirmation()
            } label: {
                ShellForwardLabel(title: String(localized: "onboarding.recovery.saved", defaultValue: "I Saved It"))
            }
            .fxButtonStyle(.primary, size: .large)
            .accessibilityIdentifier(AccessibilityID.Onboarding.recoveryKeySaved)
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// Confirm 2 randomly chosen groups (§5.3).
struct ConfirmRecoveryKeyStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    @FocusState private var focusedPosition: Int?

    var body: some View {
        OnboardingStepLayout(
            title: String(localized: "onboarding.confirm.title", defaultValue: "Confirm your recovery key"),
            subtitle: String(
                localized: "onboarding.confirm.subtitle",
                defaultValue: "Enter the requested groups from the key you saved."
            ),
            error: viewModel.error
        ) {
            HStack(alignment: .top, spacing: Theme.Spacing.large) {
                ForEach(Array(viewModel.confirmationIndices.enumerated()), id: \.offset) { position, groupIndex in
                    if viewModel.confirmationInputs.indices.contains(position) {
                        let label = String(localized: "onboarding.confirm.group", defaultValue: "Group \(groupIndex + 1)")
                        VStack(alignment: .leading, spacing: Theme.Spacing.mediumMinus) {
                            SectionLabel(label)
                                .accessibilityHidden(true)
                            TextField(label, text: $viewModel.confirmationInputs[position])
                                .autocorrectionDisabled()
                                .focused($focusedPosition, equals: position)
                                .onSubmit { viewModel.confirmRecoveryKey() }
                                .fxInputField(
                                    .rounded,
                                    isFocused: focusedPosition == position,
                                    isInvalid: viewModel.confirmationFailed,
                                    isMonospaced: true
                                )
                                .frame(width: Theme.Layout.recoveryGroupFieldWidth + Theme.Spacing.xxLarge)
                                .accessibilityLabel(label)
                                .accessibilityIdentifier(AccessibilityID.Onboarding.confirmGroup(groupIndex))
                        }
                    }
                }
            }
            if viewModel.confirmationFailed {
                Text(String(
                    localized: "onboarding.confirm.mismatch",
                    defaultValue: "That does not match your recovery key. Check the groups or go back to the key."
                ))
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.danger)
                .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Button(String(localized: "onboarding.confirm.back", defaultValue: "Show Key Again")) {
                viewModel.backToRecoveryKey()
            }
            .fxButtonStyle(.outline, size: .large)
            Button {
                viewModel.confirmRecoveryKey()
            } label: {
                ShellForwardLabel(title: String(localized: "onboarding.confirm.continue", defaultValue: "Confirm"))
            }
            .fxButtonStyle(.primary, size: .large)
            .accessibilityIdentifier(AccessibilityID.Onboarding.confirm)
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canConfirmRecoveryKey)
        }
        .onAppear {
            focusedPosition = 0
        }
    }
}

/// Touch ID (signed builds only, D14).
struct TouchIDStepView: View {
    let viewModel: OnboardingViewModel

    var body: some View {
        OnboardingStepLayout(
            title: String(localized: "onboarding.touchID.title", defaultValue: "Unlock with Touch ID"),
            subtitle: String(
                localized: "onboarding.touchID.subtitle",
                defaultValue: "Use your fingerprint instead of typing the master password. FX Vault still asks for the password after a restart and at least every \(Timeouts.passwordMaxAge.wholeDays) days."
            ),
            error: viewModel.error,
            isWorking: viewModel.isWorking
        ) {
            if let reason = viewModel.touchIDUnavailableReason {
                Banner(.warning, message: reason.localizedMessage, systemImage: "touchid")
            }
        } footer: {
            Button(String(localized: "onboarding.touchID.skip", defaultValue: "Not Now")) {
                viewModel.skipTouchID()
            }
            .fxButtonStyle(.outline, size: .large)
            Button {
                Task { await viewModel.enableTouchID() }
            } label: {
                Label(String(localized: "onboarding.touchID.enable", defaultValue: "Turn On Touch ID"), systemImage: "touchid")
            }
            .fxButtonStyle(.primary, size: .large)
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canEnableTouchID)
        }
    }
}

/// Done.
struct DoneStepView: View {
    let viewModel: OnboardingViewModel

    var body: some View {
        OnboardingStepLayout(
            title: String(localized: "onboarding.done.title", defaultValue: "Your vault is ready"),
            subtitle: viewModel.isTouchIDEnabled
                ? String(
                    localized: "onboarding.done.subtitleTouchID",
                    defaultValue: "Touch ID is on. FX Vault locks when your Mac sleeps, the screen locks, the window closes, or after a few idle minutes."
                )
                : String(
                    localized: "onboarding.done.subtitle",
                    defaultValue: "FX Vault locks when your Mac sleeps, the screen locks, the window closes, or after a few idle minutes."
                ),
            error: viewModel.error
        ) {
            Button {
                viewModel.finish()
            } label: {
                ShellForwardLabel(title: String(localized: "onboarding.done.open", defaultValue: "Open FX Vault"))
            }
            .fxButtonStyle(.primary, size: .large)
            .accessibilityIdentifier(AccessibilityID.Onboarding.openVault)
            .keyboardShortcut(.defaultAction)
        }
    }
}
