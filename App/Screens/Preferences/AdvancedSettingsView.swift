import AppKit
import SwiftUI
import VaultCore

/// Preferences › Advanced: gh path and override, telemetry note, vault folder, Reset vault, as
/// hairline groups (docs/DESIGN.md, "Settings").
struct AdvancedSettingsView: View {
    @Bindable var viewModel: PreferencesViewModel
    @FocusState private var isOverrideFocused: Bool

    var body: some View {
        PreferencesPage {
            PreferencesSection(
                String(localized: "settings.advanced.gh.section", defaultValue: "GitHub CLI"),
                footnote: String(
                    localized: "settings.advanced.gh.telemetry",
                    defaultValue: "FX Vault disables gh telemetry for its own calls."
                )
            ) {
                HStack(spacing: Theme.Spacing.large) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                        GHStatusRow(status: viewModel.ghStatus)
                        Text(String(
                            localized: "settings.advanced.gh.requirement",
                            defaultValue: "FX Vault requires gh \(Limits.minimumGHVersion) or later."
                        ))
                        .fxTextStyle(.caption)
                        .foregroundStyle(Theme.Colors.mutedText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button(String(localized: "settings.advanced.gh.recheck", defaultValue: "Check Again")) {
                        Task { await viewModel.recheckGH() }
                    }
                    .fxButtonStyle(.secondary)
                }
                .padding(.vertical, Theme.Spacing.medium)
                .padding(.horizontal, Theme.Spacing.large)
                HairlineDivider()
                PreferencesBlock(spacing: Theme.Spacing.mediumMinus) {
                    SectionLabel(String(localized: "settings.advanced.gh.override", defaultValue: "gh path override"))
                        .accessibilityHidden(true)
                    HStack(spacing: Theme.Spacing.small) {
                        TextField(
                            String(localized: "settings.advanced.gh.override", defaultValue: "gh path override"),
                            text: $viewModel.ghPathOverride,
                            prompt: Text(String(localized: "settings.advanced.gh.override.prompt", defaultValue: "Automatic"))
                                .foregroundStyle(Theme.Colors.subtleText)
                        )
                        .autocorrectionDisabled()
                        .focused($isOverrideFocused)
                        .fxInputField(.rounded, isFocused: isOverrideFocused, isMonospaced: true)
                        Button(String(localized: "settings.advanced.gh.choose", defaultValue: "Choose…")) {
                            chooseGH()
                        }
                        .fxButtonStyle(.secondary)
                    }
                }
            }
            PreferencesSection(String(localized: "settings.advanced.vault.section", defaultValue: "Vault")) {
                PreferencesBlock {
                    HStack(spacing: Theme.Spacing.small) {
                        Button(String(localized: "settings.advanced.vault.reveal", defaultValue: "Reveal Vault Folder in Finder")) {
                            if let url = viewModel.vaultFolderURL {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                        .fxButtonStyle(.secondary)
                        .disabled(viewModel.vaultFolderURL == nil)
                        Spacer(minLength: Theme.Spacing.small)
                        Button(String(localized: "settings.advanced.vault.reset", defaultValue: "Reset Vault…"), role: .destructive) {
                            viewModel.beginResetVault()
                        }
                        .fxButtonStyle(.outline)
                        .disabled(!viewModel.canStartReset)
                    }
                }
            }
        }
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

/// Reset vault: master password plus typing "reset" (D30). The final confirm is the one
/// destructive pill.
private struct ResetVaultSheet: View {
    @Bindable var viewModel: PreferencesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SheetHeader(
                label: String(localized: "settings.reset.label", defaultValue: "Vault"),
                title: String(localized: "settings.reset.title", defaultValue: "Reset vault?"),
                subtitle: String(
                    localized: "settings.reset.subtitle",
                    defaultValue: "This permanently erases every repository, secret and variable stored in FX Vault on this Mac, and turns off Touch ID. Nothing on GitHub changes. This cannot be undone."
                )
            )
            FXTextField(
                label: String(localized: "settings.reset.password", defaultValue: "Master password"),
                text: $viewModel.resetPassword,
                isSecure: true
            )
            .textContentType(.password)
            FXTextField(
                label: String(
                    localized: "settings.reset.confirm",
                    defaultValue: "Type \(PreferencesViewModel.resetConfirmationWord) to confirm"
                ),
                text: $viewModel.resetConfirmationText,
                prompt: PreferencesViewModel.resetConfirmationWord,
                isMonospaced: true
            )
            .autocorrectionDisabled()
            if let error = viewModel.resetError {
                InlineErrorView(error: error)
            }
            ShellFooter(isWorking: viewModel.isResetting) {
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    viewModel.cancelResetVault()
                }
                .fxButtonStyle(.secondary, size: .large)
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "settings.reset.submit", defaultValue: "Erase Vault"), role: .destructive) {
                    Task { await viewModel.resetVault() }
                }
                .fxButtonStyle(.destructive, size: .large)
                .disabled(!viewModel.canResetVault)
            }
        }
        .fxSheetContent(width: Theme.Layout.sheetWidth)
    }
}
