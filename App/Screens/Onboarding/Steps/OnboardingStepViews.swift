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

/// Welcome (board Main): the mark, what FX Vault is, Create Vault, and the three phases ahead.
struct WelcomeStepView: View {
    let viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: Theme.Spacing.xLargePlus) {
            BrandMark(size: Theme.Layout.brandMarkLarge, center: .outlined)
                .accessibilityHidden(true)
            VStack(spacing: Theme.Spacing.mediumMinus) {
                Text(verbatim: "FX Vault")
                    .fxTextStyle(.display)
                    .foregroundStyle(Theme.Colors.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(String(
                    localized: "onboarding.welcome.subtitle",
                    defaultValue: "Your GitHub and Azure Key Vault secrets in one place, readable as notes."
                ))
                .fxTextStyle(.lead)
                .foregroundStyle(Theme.Colors.mutedText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.Layout.onboardingTextWidth)
            }
            if let error = viewModel.error {
                InlineErrorView(error: error)
                    .frame(maxWidth: Theme.Layout.onboardingTextWidth)
            }
            Button {
                viewModel.start()
            } label: {
                ShellForwardLabel(title: String(localized: "onboarding.welcome.start", defaultValue: "Create Vault"))
            }
            .fxButtonStyle(.primary, size: .large)
            .accessibilityIdentifier(AccessibilityID.Onboarding.createVault)
            .keyboardShortcut(.defaultAction)
            VStack(spacing: Theme.Spacing.small) {
                OnboardingPhaseHeader(current: nil)
                Text(String(localized: "onboarding.welcome.local", defaultValue: "Encrypted on this Mac"))
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.subtleText)
            }
        }
        .padding(Theme.Spacing.xHuge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Create password: ≥ 12 characters and ≥ 60 bits, a generated passphrase, confirmation (D8).
struct CreatePasswordStepView: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        OnboardingStepLayout(
            title: String(localized: "onboarding.password.title", defaultValue: "Create a master password."),
            subtitle: String(
                localized: "onboarding.password.subtitle",
                defaultValue: "It encrypts your vault on this Mac."
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

            OnboardingNote(String(
                localized: "onboarding.password.note",
                defaultValue: "It can't be recovered. Your recovery key, next, is the only way back in."
            ))
        } footer: {
            Button(String(localized: "onboarding.back", defaultValue: "Back")) {
                viewModel.backToWelcome()
            }
            .fxButtonStyle(.outline, size: .large)
            .accessibilityIdentifier(AccessibilityID.Onboarding.back)
            .disabled(viewModel.isWorking)
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

/// Recovery key: the grid, Copy, and "I saved it offline" before Continue (§5.3). No Back: the
/// vault already exists here, and the key is never shown again after this step.
struct RecoveryKeyStepView: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        OnboardingStepLayout(
            title: String(localized: "onboarding.recovery.title", defaultValue: "Save your recovery key."),
            subtitle: String(
                localized: "onboarding.recovery.subtitle",
                defaultValue: "The only way in if you forget your password."
            ),
            error: viewModel.error
        ) {
            RecoveryKeyGridView(groups: viewModel.recoveryKeyGroups)
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
            FXCheckboxRow(
                title: String(localized: "onboarding.recovery.savedCheck", defaultValue: "I saved it offline"),
                isOn: $viewModel.hasSavedRecoveryKey
            )
            .accessibilityIdentifier(AccessibilityID.Onboarding.recoveryKeySavedCheck)
            OnboardingNote(String(
                localized: "onboarding.recovery.note",
                defaultValue: "Shown once. Not stored on this Mac."
            ))
        } footer: {
            Button {
                viewModel.continueToConfirmation()
            } label: {
                ShellForwardLabel(title: String(localized: "onboarding.recovery.continue", defaultValue: "Continue"))
            }
            .fxButtonStyle(.primary, size: .large)
            .accessibilityIdentifier(AccessibilityID.Onboarding.recoveryKeySaved)
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canContinueFromRecoveryKey)
        }
    }
}

/// Confirm 2 randomly chosen groups (§5.3).
struct ConfirmRecoveryKeyStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    @FocusState private var focusedPosition: Int?

    var body: some View {
        OnboardingStepLayout(
            title: String(localized: "onboarding.confirm.title", defaultValue: "Confirm your recovery key."),
            subtitle: subtitle,
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
            OnboardingNote(String(localized: "onboarding.confirm.note", defaultValue: "Back shows the key again."))
        } footer: {
            Button(String(localized: "onboarding.back", defaultValue: "Back")) {
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

    /// "Type groups 04 and 11 from the copy you saved." with the groups this run asks for.
    private var subtitle: String {
        let groups = viewModel.confirmationIndices.map { StepCounter.padded($0 + 1) }
            .formatted(.list(type: .and))
        return String(
            localized: "onboarding.confirm.subtitle",
            defaultValue: "Type groups \(groups) from the copy you saved."
        )
    }
}

/// Touch ID (signed builds only, D14).
struct TouchIDStepView: View {
    let viewModel: OnboardingViewModel

    var body: some View {
        OnboardingStepLayout(
            title: String(localized: "onboarding.touchID.title", defaultValue: "Use Touch ID?"),
            subtitle: String(
                localized: "onboarding.touchID.subtitle",
                defaultValue: "Faster unlocks. You can change this in Settings."
            ),
            error: viewModel.error,
            isWorking: viewModel.isWorking
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                OnboardingFact(
                    systemImage: "touchid",
                    text: String(
                        localized: "onboarding.touchID.fact.unlock",
                        defaultValue: "Unlock and reveal with your fingerprint"
                    )
                )
                OnboardingFact(
                    systemImage: "lock",
                    text: String(
                        localized: "onboarding.touchID.fact.password",
                        defaultValue: "Password still asked after a restart and every \(Timeouts.passwordMaxAge.wholeDays) days"
                    )
                )
            }
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

/// A short caption under a step's content (board copy such as "Shown once. Not stored on this Mac.").
private struct OnboardingNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .fxTextStyle(.caption)
            .foregroundStyle(Theme.Colors.subtleText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One line of what a choice does: a symbol and a sentence (board Touch ID).
private struct OnboardingFact: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fxTextStyle(.body)
                .foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.Colors.mutedText)
        }
    }
}
