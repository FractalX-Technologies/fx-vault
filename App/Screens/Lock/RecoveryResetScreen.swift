import SwiftUI
import VaultCore

/// Recovery reset (§5.2, D9): recovery key and new password, then the **new** recovery key. One
/// card on the lock screen's dotted ground.
struct RecoveryResetScreen: View {
    @Bindable var viewModel: RecoveryResetViewModel
    let onCancel: () -> Void
    @FocusState private var isKeyFocused: Bool

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
