import SwiftUI
import VaultCore

/// Recovery reset (§5.2, D9): recovery key and new password, then the **new** recovery key. One
/// card on the lock screen's dotted ground. Without the key either, the last resort erases the
/// vault after typing the confirmation word.
struct RecoveryResetScreen: View {
    @Bindable var viewModel: RecoveryResetViewModel
    let onCancel: () -> Void
    @FocusState private var isKeyFocused: Bool
    @FocusState private var isEraseConfirmationFocused: Bool

    private var sectionLabel: String {
        String(localized: "recoveryReset.label", defaultValue: "Recovery")
    }

    var body: some View {
        ShellCardLayout {
            switch viewModel.step {
            case .enterKey:
                enterKey
            case .showNewKey:
                showNewKey
            case .erase:
                erase
            }
            if let error = viewModel.error {
                InlineErrorView(error: error)
            }
        }
    }

    @ViewBuilder private var enterKey: some View {
        SheetHeader(
            label: sectionLabel,
            title: String(localized: "recoveryReset.title", defaultValue: "Reset your master password"),
            subtitle: String(
                localized: "recoveryReset.subtitle",
                defaultValue: "Enter your recovery key and choose a new master password. FX Vault then replaces the vault key and gives you a new recovery key; the old one stops working."
            )
        )
        VStack(alignment: .leading, spacing: Theme.Spacing.mediumMinus) {
            SectionLabel(String(localized: "recoveryReset.key.label", defaultValue: "Recovery key"))
                .accessibilityHidden(true)
            TextField(
                String(localized: "recoveryReset.key.label", defaultValue: "Recovery key"),
                text: $viewModel.recoveryKeyText,
                prompt: Text(String(
                    localized: "recoveryReset.key.placeholder",
                    defaultValue: "Recovery key (\(Limits.recoveryKeyCharacters) characters)"
                ))
                .foregroundStyle(Theme.Colors.subtleText),
                axis: .vertical
            )
            .autocorrectionDisabled()
            .focused($isKeyFocused)
            .disabled(viewModel.isWorking)
            .padding(.vertical, Theme.Spacing.medium)
            .fxInputField(.rounded, isFocused: isKeyFocused, isMonospaced: true)
        }

        NewPasswordFields(
            password: $viewModel.newPassword,
            confirmation: $viewModel.passwordConfirmation,
            strength: viewModel.strength,
            showsMismatch: viewModel.showsMismatch
        ) {
            Task { await viewModel.reset() }
        }
        .disabled(viewModel.isWorking)

        ShellFooter(isWorking: viewModel.isWorking) {
            Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                viewModel.cancel()
                onCancel()
            }
            .fxButtonStyle(.secondary, size: .large)
            .keyboardShortcut(.cancelAction)
            Button(String(localized: "recoveryReset.submit", defaultValue: "Reset Password")) {
                Task { await viewModel.reset() }
            }
            .fxButtonStyle(.primary, size: .large)
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canReset)
        }
        .padding(.top, Theme.Spacing.small)

        Button(String(localized: "recoveryReset.forgotKey", defaultValue: "No recovery key either? Erase vault…")) {
            viewModel.beginErase()
        }
        .fxLinkButtonStyle()
        .disabled(viewModel.isWorking)
        .accessibilityIdentifier(AccessibilityID.Recovery.forgotKey)
    }

    @ViewBuilder private var erase: some View {
        SheetHeader(
            label: sectionLabel,
            title: String(localized: "recoveryReset.erase.title", defaultValue: "Erase vault and start over?"),
            subtitle: String(
                localized: "recoveryReset.erase.subtitle",
                defaultValue: "Without your master password or recovery key, nobody can open this vault again, not even FX Vault. Erasing it deletes every repository, secret and variable stored on this Mac and turns off Touch ID, then you create a new vault. Nothing on GitHub changes. This cannot be undone."
            )
        )
        VStack(alignment: .leading, spacing: Theme.Spacing.mediumMinus) {
            SectionLabel(eraseConfirmLabel)
                .accessibilityHidden(true)
            TextField(text: $viewModel.eraseConfirmationText, prompt: Text(verbatim: PreferencesViewModel.resetConfirmationWord)) {
                Text(eraseConfirmLabel)
            }
            .autocorrectionDisabled()
            .focused($isEraseConfirmationFocused)
            .disabled(viewModel.isWorking)
            .onSubmit { Task { await viewModel.erase() } }
            .fxInputField(.rounded, isFocused: isEraseConfirmationFocused, isMonospaced: true)
            .accessibilityIdentifier(AccessibilityID.Recovery.eraseConfirmation)
        }
        ShellFooter(isWorking: viewModel.isWorking) {
            Button(String(localized: "onboarding.back", defaultValue: "Back")) {
                viewModel.cancelErase()
            }
            .fxButtonStyle(.secondary, size: .large)
            .keyboardShortcut(.cancelAction)
            Button(String(localized: "settings.reset.submit", defaultValue: "Erase Vault"), role: .destructive) {
                Task { await viewModel.erase() }
            }
            .fxButtonStyle(.destructive, size: .large)
            .disabled(!viewModel.canErase)
            .accessibilityIdentifier(AccessibilityID.Recovery.erase)
        }
        .padding(.top, Theme.Spacing.small)
        .onAppear { isEraseConfirmationFocused = true }
    }

    private var eraseConfirmLabel: String {
        String(
            localized: "settings.reset.confirm",
            defaultValue: "Type \(PreferencesViewModel.resetConfirmationWord) to confirm"
        )
    }

    @ViewBuilder private var showNewKey: some View {
        SheetHeader(
            label: sectionLabel,
            title: String(localized: "recoveryReset.newKey.title", defaultValue: "Save your new recovery key"),
            subtitle: String(
                localized: "recoveryReset.newKey.subtitle",
                defaultValue: "Your master password was changed and the vault key replaced. Your old recovery key no longer works."
            )
        )
        RecoveryKeyGridView(groups: viewModel.newRecoveryKeyGroups)
        HStack(spacing: Theme.Spacing.medium) {
            Button(String(localized: "recoveryReset.newKey.copy", defaultValue: "Copy")) {
                viewModel.copyNewRecoveryKey()
            }
            .fxButtonStyle(.outline)
            if viewModel.hasCopiedNewKey {
                Text(String(
                    localized: "onboarding.recovery.copied",
                    defaultValue: "Copied. The clipboard clears in \(Timeouts.clipboardClear.wholeSeconds) seconds."
                ))
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
            }
        }
        FXCheckboxRow(
            title: String(localized: "recoveryReset.newKey.saved", defaultValue: "I saved the new recovery key"),
            isOn: $viewModel.hasSavedNewKey
        )
        ShellFooter {
            Button(String(localized: "recoveryReset.newKey.finish", defaultValue: "Open FX Vault")) {
                viewModel.finish()
            }
            .fxButtonStyle(.primary, size: .large)
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canFinish)
        }
    }
}
