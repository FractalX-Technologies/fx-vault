import SwiftUI

/// Reset vault (board Settings-Security): its own card at the end of the Security tab, also
/// while the vault is locked, since the reset asks for the master password itself.
struct ResetVaultSection: View {
    let viewModel: PreferencesViewModel

    var body: some View {
        PreferencesSection(nil) {
            PreferencesRow(
                String(localized: "settings.advanced.vault.resetRow", defaultValue: "Reset vault"),
                detail: String(
                    localized: "settings.advanced.vault.reset.detail",
                    defaultValue: "Erases everything stored in FX Vault on this Mac"
                )
            ) {
                Button(String(localized: "settings.advanced.vault.reset", defaultValue: "Reset Vault…"), role: .destructive) {
                    viewModel.beginResetVault()
                }
                .fxButtonStyle(.outlineDestructive, size: .compact)
                .disabled(!viewModel.canStartReset)
            }
        }
    }
}

/// Reset vault (board Reset-Confirm): master password plus typing "reset" (D30). The final
/// confirm is the one danger-filled button. Internal, not private, so the visual snapshot
/// can render it.
struct ResetVaultSheet: View {
    @Bindable var viewModel: PreferencesViewModel
    @FocusState private var focusedField: Field?

    private enum Field {
        case password
        case confirmation
    }

    var body: some View {
        DialogSheet(
            title: String(localized: "settings.reset.title", defaultValue: "Reset vault?"),
            subtitle: String(
                localized: "settings.reset.subtitle",
                defaultValue: "This permanently erases every repository, secret and variable stored in FX Vault on this Mac, and turns off Touch ID. Nothing on GitHub changes. This cannot be undone."
            ),
            isWorking: viewModel.isResetting
        ) {
            DialogStackedField(String(localized: "settings.reset.password", defaultValue: "Master password")) {
                SecureField(text: $viewModel.resetPassword) {
                    Text(String(localized: "settings.reset.password", defaultValue: "Master password"))
                }
                .textContentType(.password)
                .focused($focusedField, equals: .password)
                .fxInputField(.dialog, isFocused: focusedField == .password, isMonospaced: true)
            }
            DialogStackedField(confirmLabel) {
                TextField(text: $viewModel.resetConfirmationText, prompt: Text(verbatim: PreferencesViewModel.resetConfirmationWord)) {
                    Text(confirmLabel)
                }
                .autocorrectionDisabled()
                .focused($focusedField, equals: .confirmation)
                .fxInputField(.dialog, isFocused: focusedField == .confirmation, isMonospaced: true)
            }
            if let error = viewModel.resetError {
                InlineErrorView(error: error)
            }
        } actions: {
            Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                viewModel.cancelResetVault()
            }
            .fxButtonStyle(.outline, size: .dialog)
            .keyboardShortcut(.cancelAction)
            Button(String(localized: "settings.reset.submit", defaultValue: "Erase Vault"), role: .destructive) {
                Task { await viewModel.resetVault() }
            }
            .fxButtonStyle(.destructive, size: .dialog)
            .disabled(!viewModel.canResetVault)
        }
        .frame(width: Theme.Layout.resetDialogWidth)
        .onAppear { focusedField = .password }
    }

    private var confirmLabel: String {
        String(
            localized: "settings.reset.confirm",
            defaultValue: "Type \(PreferencesViewModel.resetConfirmationWord) to confirm"
        )
    }
}
