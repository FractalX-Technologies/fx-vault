import SwiftUI
import VaultCore

/// Preferences › Security (board Settings-Security): Touch ID, then the master password and a new
/// recovery key, unlocked only, then Reset vault. While the vault is locked only Reset vault
/// stays: it asks for the master password itself.
struct SecuritySettingsScreen: View {
    @Bindable var preferences: PreferencesViewModel
    @Bindable var viewModel: SecuritySettingsViewModel

    var body: some View {
        Group {
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
            } else if preferences.canStartReset {
                PreferencesPage {
                    PreferencesFootnote(String(
                        localized: "settings.security.locked.note",
                        defaultValue: "Unlock FX Vault to change Touch ID, the master password and the recovery key."
                    ))
                    ResetVaultSection(viewModel: preferences)
                }
            } else {
                VaultSettingsLockedView()
            }
        }
        .sheet(isPresented: $preferences.isShowingResetVault) {
            ResetVaultSheet(viewModel: preferences)
        }
    }

    private var form: some View {
        PreferencesPage {
            PreferencesSection(nil, footnote: touchIDFootnote) {
                PreferencesRow(touchIDLabel) {
                    Toggle(
                        touchIDLabel,
                        isOn: Binding(
                            get: { viewModel.isBiometricsEnabled },
                            set: { viewModel.requestTouchID(enabled: $0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!viewModel.canToggleTouchID && !viewModel.isBiometricsEnabled)
                }
            }
            PreferencesSection(nil) {
                PreferencesRow(String(localized: "settings.security.password.section", defaultValue: "Master password")) {
                    Button(String(localized: "settings.security.changePassword", defaultValue: "Change Master Password…")) {
                        viewModel.present(.changePassword)
                    }
                    .fxButtonStyle(.outline, size: .compact)
                }
                HairlineDivider()
                PreferencesRow(
                    String(localized: "settings.security.recoveryKey", defaultValue: "Recovery key"),
                    detail: String(localized: "settings.security.recoveryKey.detail", defaultValue: "Your current key stops working")
                ) {
                    Button(String(localized: "settings.security.newRecoveryKey.short", defaultValue: "New Recovery Key…")) {
                        viewModel.present(.newRecoveryKey)
                    }
                    .fxButtonStyle(.outline, size: .compact)
                }
            }
            ResetVaultSection(viewModel: preferences)
        }
    }

    private var touchIDLabel: String {
        String(localized: "settings.security.touchID.toggle", defaultValue: "Unlock with Touch ID")
    }

    private var touchIDFootnote: String {
        if let reason = viewModel.biometricsUnavailableReason {
            return reason.localizedMessage
        }
        return String(
            localized: "settings.security.touchID.policy",
            defaultValue: "FX Vault still asks for the master password after a restart and at least every \(Timeouts.passwordMaxAge.wholeDays) days."
        )
    }
}

/// The password-gated sheets of the Security tab, laid out as FractalX sheets.
private struct SecuritySheetView: View {
    @Bindable var viewModel: SecuritySettingsViewModel
    let sheet: SecuritySettingsViewModel.Sheet

    private var sheetLabel: String {
        String(localized: "settings.security.sheet.label", defaultValue: "Security")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
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
        .fxSheetContent(width: sheet == .showRecoveryKey ? Theme.Layout.cardWidth : Theme.Layout.sheetWidth)
    }

    private var currentPasswordField: some View {
        FXTextField(
            label: String(localized: "settings.security.currentPassword", defaultValue: "Current master password"),
            text: $viewModel.currentPassword,
            isSecure: true
        )
        .textContentType(.password)
    }

    @ViewBuilder private var touchID: some View {
        let isEnabling = sheet == .enableTouchID
        SheetHeader(
            label: sheetLabel,
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
        SheetHeader(
            label: sheetLabel,
            title: String(localized: "settings.security.changePassword.title", defaultValue: "Change master password"),
            subtitle: nil
        )
        currentPasswordField
        NewPasswordFields(
            password: $viewModel.newPassword,
            confirmation: $viewModel.newPasswordConfirmation,
            strength: viewModel.newPasswordStrength,
            showsMismatch: !viewModel.newPasswordConfirmation.isEmpty && !viewModel.newPasswordsMatch
        )
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            FXCheckboxRow(
                title: String(
                    localized: "settings.security.changePassword.rotate",
                    defaultValue: "My password may be compromised: rotate the vault key"
                ),
                isOn: $viewModel.rotateVaultKey
            )
            Text(String(
                localized: "settings.security.changePassword.rotate.note",
                defaultValue: "Rotating re-encrypts every value and gives you a new recovery key."
            ))
            .fxTextStyle(.caption)
            .foregroundStyle(Theme.Colors.mutedText)
            .fixedSize(horizontal: false, vertical: true)
        }
        buttons(
            title: String(localized: "settings.security.changePassword.submit", defaultValue: "Change Password"),
            isEnabled: viewModel.canChangePassword
        ) {
            await viewModel.changePassword()
        }
    }

    @ViewBuilder private var newRecoveryKey: some View {
        SheetHeader(
            label: sheetLabel,
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
        SheetHeader(
            label: sheetLabel,
            title: String(localized: "settings.security.showRecoveryKey.title", defaultValue: "Save your new recovery key"),
            subtitle: String(
                localized: "settings.security.showRecoveryKey.subtitle",
                defaultValue: "Store it in a password manager. FX Vault will not show it again, and your previous recovery key no longer works."
            )
        )
        RecoveryKeyGridView(groups: viewModel.recoveryKeyGroups)
        ShellFooter {
            Button(String(localized: "settings.security.showRecoveryKey.copy", defaultValue: "Copy")) {
                viewModel.copyRecoveryKey()
            }
            .fxButtonStyle(.outline, size: .large)
        } buttons: {
            Button(String(localized: "settings.security.showRecoveryKey.done", defaultValue: "I Saved It")) {
                viewModel.acknowledgeRecoveryKey()
            }
            .fxButtonStyle(.primary, size: .large)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func buttons(title: String, isEnabled: Bool, action: @escaping () async -> Void) -> some View {
        ShellFooter(isWorking: viewModel.isWorking) {
            Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                viewModel.dismissSheet()
            }
            .fxButtonStyle(.secondary, size: .large)
            .keyboardShortcut(.cancelAction)
            Button(title) {
                Task { await action() }
            }
            .fxButtonStyle(.primary, size: .large)
            .keyboardShortcut(.defaultAction)
            .disabled(!isEnabled)
        }
    }
}
