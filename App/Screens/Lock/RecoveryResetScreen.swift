import SwiftUI
import VaultCore

/// Recovery reset (§5.2, D9): recovery key and new password, then the **new** recovery key.
struct RecoveryResetScreen: View {
    @Bindable var viewModel: RecoveryResetViewModel
    let onCancel: () -> Void

    var body: some View {
        CenteredCard {
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
        CardHeader(
            systemImage: "key.horizontal",
            title: String(localized: "recoveryReset.title", defaultValue: "Reset your master password"),
            subtitle: String(
                localized: "recoveryReset.subtitle",
                defaultValue: "Enter your recovery key and choose a new master password. FX Vault then replaces the vault key and gives you a new recovery key; the old one stops working."
            )
        )
        TextField(
            String(localized: "recoveryReset.key.placeholder", defaultValue: "Recovery key (\(Limits.recoveryKeyCharacters) characters)"),
            text: $viewModel.recoveryKeyText,
            axis: .vertical
        )
        .font(Theme.Typography.monospaced)
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        .disabled(viewModel.isWorking)

        NewPasswordFields(
            password: $viewModel.newPassword,
            confirmation: $viewModel.passwordConfirmation,
            strength: viewModel.strength,
            showsMismatch: viewModel.showsMismatch
        ) {
            Task { await viewModel.reset() }
        }
        .disabled(viewModel.isWorking)

        HStack {
            Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                viewModel.cancel()
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            if viewModel.isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            Button(String(localized: "recoveryReset.submit", defaultValue: "Reset Password")) {
                Task { await viewModel.reset() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canReset)
        }
    }

    @ViewBuilder private var showNewKey: some View {
        CardHeader(
            systemImage: "key.viewfinder",
            title: String(localized: "recoveryReset.newKey.title", defaultValue: "Save your new recovery key"),
            subtitle: String(
                localized: "recoveryReset.newKey.subtitle",
                defaultValue: "Your master password was changed and the vault key replaced. Your old recovery key no longer works."
            )
        )
        RecoveryKeyGridView(groups: viewModel.newRecoveryKeyGroups)
        HStack {
            Button(String(localized: "recoveryReset.newKey.copy", defaultValue: "Copy")) {
                viewModel.copyNewRecoveryKey()
            }
            if viewModel.hasCopiedNewKey {
                Text(String(
                    localized: "onboarding.recovery.copied",
                    defaultValue: "Copied. The clipboard clears in \(Timeouts.clipboardClear.wholeSeconds) seconds."
                ))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        Toggle(
            String(localized: "recoveryReset.newKey.saved", defaultValue: "I saved the new recovery key"),
            isOn: $viewModel.hasSavedNewKey
        )
        HStack {
            Spacer()
            Button(String(localized: "recoveryReset.newKey.finish", defaultValue: "Open FX Vault")) {
                viewModel.finish()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canFinish)
        }
    }
}
