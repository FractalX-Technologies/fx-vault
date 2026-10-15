import SwiftUI
import VaultCore

/// Preferences › Security: Touch ID, master password, recovery key, clipboard (unlocked only).
struct SecuritySettingsScreen: View {
    let preferences: PreferencesViewModel
    @Bindable var viewModel: SecuritySettingsViewModel

    var body: some View {
        if preferences.isVaultSettingsAvailable {
            form
                .onAppear { viewModel.refresh() }
                .sheet(item: $viewModel.activeSheet, onDismiss: {
                    // Esc or a lock closed the sheet: drop typed passwords and any key on screen.
                    if viewModel.activeSheet == nil {
                        viewModel.dismissAll()
                    }
                }) { sheet in
                    SecuritySheetView(viewModel: viewModel, sheet: sheet)
                }
        } else {
            VaultSettingsLockedView()
        }
    }

    private var form: some View {
        Form {
            Section(String(localized: "settings.security.touchID.section", defaultValue: "Touch ID")) {
                Toggle(
                    String(localized: "settings.security.touchID.toggle", defaultValue: "Unlock with Touch ID"),
                    isOn: Binding(
                        get: { viewModel.isBiometricsEnabled },
                        set: { viewModel.requestTouchID(enabled: $0) }
                    )
                )
                .disabled(!viewModel.canToggleTouchID && !viewModel.isBiometricsEnabled)
                if let reason = viewModel.biometricsUnavailableReason {
                    Text(reason.localizedMessage)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            Section(String(localized: "settings.security.password.section", defaultValue: "Master password")) {
                Button(String(localized: "settings.security.changePassword", defaultValue: "Change Master Password…")) {
                    viewModel.present(.changePassword)
                }
                Button(String(localized: "settings.security.newRecoveryKey", defaultValue: "Create New Recovery Key…")) {
                    viewModel.present(.newRecoveryKey)
                }
            }
            Section(String(localized: "settings.security.clipboard.section", defaultValue: "Clipboard")) {
                Text(String(
                    localized: "settings.security.clipboard.info",
                    defaultValue: "Copied values stay on this Mac (no Universal Clipboard), are hidden from clipboard managers, and are cleared after \(Timeouts.clipboardClear.wholeSeconds) seconds or when FX Vault locks, unless you copied something else since."
                ))
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The password-gated sheets of the Security tab.
private struct SecuritySheetView: View {
    @Bindable var viewModel: SecuritySettingsViewModel
    let sheet: SecuritySettingsViewModel.Sheet

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            switch sheet {
            case .enableTouchID, .disableTouchID:
                touchID
            case .changePassword:
                changePassword
            case .newRecoveryKey:
                newRecoveryKey
            case .showRecoveryKey:
                showRecoveryKey
            }
            if let error = viewModel.error {
                InlineErrorView(error: error)
            }
        }
        .padding(Theme.Spacing.xLarge)
        .frame(width: sheet == .showRecoveryKey ? Theme.Layout.cardWidth : Theme.Layout.sheetWidth)
    }

    private var currentPasswordField: some View {
        SecureField(
            String(localized: "settings.security.currentPassword", defaultValue: "Current master password"),
            text: $viewModel.currentPassword
        )
        .textContentType(.password)
        .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder private var touchID: some View {
        let isEnabling = sheet == .enableTouchID
        CardHeader(
            systemImage: "touchid",
            title: isEnabling
                ? String(localized: "settings.security.touchID.enable.title", defaultValue: "Turn on Touch ID")
                : String(localized: "settings.security.touchID.disable.title", defaultValue: "Turn off Touch ID"),
            subtitle: String(
                localized: "settings.security.touchID.subtitle",
                defaultValue: "Enter your master password to continue."
            )
        )
        currentPasswordField
            .onSubmit { Task { await viewModel.confirmTouchIDChange() } }
        buttons(
            title: isEnabling
                ? String(localized: "settings.security.touchID.enable", defaultValue: "Turn On")
                : String(localized: "settings.security.touchID.disable", defaultValue: "Turn Off"),
            isEnabled: !viewModel.currentPassword.isEmpty && !viewModel.isWorking
        ) {
            await viewModel.confirmTouchIDChange()
        }
    }

    @ViewBuilder private var changePassword: some View {
        CardHeader(
            systemImage: "key",
            title: String(localized: "settings.security.changePassword.title", defaultValue: "Change master password")
        )
        currentPasswordField
        NewPasswordFields(
            password: $viewModel.newPassword,
            confirmation: $viewModel.newPasswordConfirmation,
            strength: viewModel.newPasswordStrength,
            showsMismatch: !viewModel.newPasswordConfirmation.isEmpty && !viewModel.newPasswordsMatch
        )
        Toggle(
            String(
                localized: "settings.security.changePassword.rotate",
                defaultValue: "My password may be compromised: rotate the vault key"
            ),
            isOn: $viewModel.rotateVaultKey
        )
        Text(String(
            localized: "settings.security.changePassword.rotate.note",
            defaultValue: "Rotating re-encrypts every value and gives you a new recovery key."
        ))
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.Colors.textSecondary)
        buttons(
            title: String(localized: "settings.security.changePassword.submit", defaultValue: "Change Password"),
            isEnabled: viewModel.canChangePassword
        ) {
            await viewModel.changePassword()
        }
    }

    @ViewBuilder private var newRecoveryKey: some View {
        CardHeader(
            systemImage: "key.viewfinder",
            title: String(localized: "settings.security.newRecoveryKey.title", defaultValue: "Create a new recovery key"),
            subtitle: String(
                localized: "settings.security.newRecoveryKey.subtitle",
                defaultValue: "Your current recovery key stops working. Enter your master password to continue."
            )
        )
        currentPasswordField
            .onSubmit { Task { await viewModel.createNewRecoveryKey() } }
        buttons(
            title: String(localized: "settings.security.newRecoveryKey.submit", defaultValue: "Create Key"),
            isEnabled: !viewModel.currentPassword.isEmpty && !viewModel.isWorking
        ) {
            await viewModel.createNewRecoveryKey()
        }
    }

    @ViewBuilder private var showRecoveryKey: some View {
        CardHeader(
            systemImage: "key.viewfinder",
            title: String(localized: "settings.security.showRecoveryKey.title", defaultValue: "Save your new recovery key"),
            subtitle: String(
                localized: "settings.security.showRecoveryKey.subtitle",
                defaultValue: "Store it in a password manager. FX Vault will not show it again, and your previous recovery key no longer works."
            )
        )
        RecoveryKeyGridView(groups: viewModel.recoveryKeyGroups)
        HStack {
            Button(String(localized: "settings.security.showRecoveryKey.copy", defaultValue: "Copy")) {
                viewModel.copyRecoveryKey()
            }
            Spacer()
            Button(String(localized: "settings.security.showRecoveryKey.done", defaultValue: "I Saved It")) {
                viewModel.acknowledgeRecoveryKey()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func buttons(title: String, isEnabled: Bool, action: @escaping () async -> Void) -> some View {
        HStack {
            Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                viewModel.dismissSheet()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            if viewModel.isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            Button(title) {
                Task { await action() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!isEnabled)
        }
    }
}
