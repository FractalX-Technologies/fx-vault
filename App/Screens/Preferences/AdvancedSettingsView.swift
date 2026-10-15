import AppKit
import SwiftUI
import VaultCore

/// Preferences › Advanced: gh path and override, telemetry note, vault folder, Reset vault.
struct AdvancedSettingsView: View {
    @Bindable var viewModel: PreferencesViewModel

    var body: some View {
        Form {
            Section(String(localized: "settings.advanced.gh.section", defaultValue: "GitHub CLI")) {
                GHStatusRow(status: viewModel.ghStatus)
                Text(String(
                    localized: "settings.advanced.gh.requirement",
                    defaultValue: "FX Vault requires gh \(Limits.minimumGHVersion) or later."
                ))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                HStack {
                    TextField(
                        String(localized: "settings.advanced.gh.override", defaultValue: "gh path override"),
                        text: $viewModel.ghPathOverride,
                        prompt: Text(String(localized: "settings.advanced.gh.override.prompt", defaultValue: "Automatic"))
                    )
                    .autocorrectionDisabled()
                    Button(String(localized: "settings.advanced.gh.choose", defaultValue: "Choose…")) {
                        chooseGH()
                    }
                }
                Button(String(localized: "settings.advanced.gh.recheck", defaultValue: "Check Again")) {
                    Task { await viewModel.recheckGH() }
                }
                Text(String(
                    localized: "settings.advanced.gh.telemetry",
                    defaultValue: "FX Vault disables gh telemetry for its own calls."
                ))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            }
            Section(String(localized: "settings.advanced.vault.section", defaultValue: "Vault")) {
                Button(String(localized: "settings.advanced.vault.reveal", defaultValue: "Reveal Vault Folder in Finder")) {
                    if let url = viewModel.vaultFolderURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .disabled(viewModel.vaultFolderURL == nil)
                Button(String(localized: "settings.advanced.vault.reset", defaultValue: "Reset Vault…"), role: .destructive) {
                    viewModel.beginResetVault()
                }
                .disabled(!viewModel.canStartReset)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $viewModel.isShowingResetVault) {
            ResetVaultSheet(viewModel: viewModel)
        }
    }

    private func chooseGH() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.ghPathOverride = url.path(percentEncoded: false)
    }
}

/// Reset vault: master password plus typing "reset" (D30).
private struct ResetVaultSheet: View {
    @Bindable var viewModel: PreferencesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            CardHeader(
                systemImage: "exclamationmark.triangle",
                title: String(localized: "settings.reset.title", defaultValue: "Reset vault?"),
                subtitle: String(
                    localized: "settings.reset.subtitle",
                    defaultValue: "This permanently erases every repository, secret and variable stored in FX Vault on this Mac, and turns off Touch ID. Nothing on GitHub changes. This cannot be undone."
                )
            )
            SecureField(
                String(localized: "settings.reset.password", defaultValue: "Master password"),
                text: $viewModel.resetPassword
            )
            .textFieldStyle(.roundedBorder)
            TextField(
                String(
                    localized: "settings.reset.confirm",
                    defaultValue: "Type \(PreferencesViewModel.resetConfirmationWord) to confirm"
                ),
                text: $viewModel.resetConfirmationText
            )
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            if let error = viewModel.resetError {
                InlineErrorView(error: error)
            }
            HStack {
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    viewModel.cancelResetVault()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if viewModel.isResetting {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(String(localized: "settings.reset.submit", defaultValue: "Erase Vault"), role: .destructive) {
                    Task { await viewModel.resetVault() }
                }
                .disabled(!viewModel.canResetVault)
            }
        }
        .padding(Theme.Spacing.xLarge)
        .frame(width: Theme.Layout.sheetWidth)
    }
}
