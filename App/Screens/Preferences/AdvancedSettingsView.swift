import AppKit
import SwiftUI
import VaultCore

/// Preferences › Advanced (board Settings-Advanced): the gh path override, the gh in use, the gh
/// trusted although another user owns it (with Revoke, v0.3.1), the telemetry note, the vault
/// folder and Reset vault, which works in every phase (docs/DESIGN.md, "Settings").
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
                PreferencesRow(overrideLabel) {
                    TextField(
                        overrideLabel,
                        text: $viewModel.ghPathOverride,
                        prompt: Text(String(localized: "settings.advanced.gh.override.prompt", defaultValue: "Automatic"))
                            .foregroundStyle(Theme.Colors.subtleText)
                    )
                    .autocorrectionDisabled()
                    .focused($isOverrideFocused)
                    .fxInputField(.dialog, isFocused: isOverrideFocused, isMonospaced: true)
                    .frame(width: Theme.Layout.settingsPathFieldWidth)
                    Button(String(localized: "settings.advanced.gh.choose", defaultValue: "Choose…")) {
                        chooseGH()
                    }
                    .fxButtonStyle(.outline, size: .compact)
                }
                HairlineDivider()
                PreferencesRow(
                    String(localized: "settings.advanced.gh.inUse", defaultValue: "In use"),
                    detail: String(
                        localized: "settings.advanced.gh.requirement.short",
                        defaultValue: "Needs gh \(Limits.minimumGHVersion) or later"
                    )
                ) {
                    GHInUseValue(status: viewModel.ghStatus)
                    Button(String(localized: "settings.advanced.gh.recheck", defaultValue: "Check Again")) {
                        Task { await viewModel.recheckGH() }
                    }
                    .fxButtonStyle(.outline, size: .compact)
                }
                if GHInUseValue.needsSentence(viewModel.ghStatus) {
                    PreferencesBlock {
                        GHStatusRow(status: viewModel.ghStatus)
                    }
                }
                if let trusted = viewModel.trustedGHBinary, let owner = viewModel.trustedGHOwner {
                    HairlineDivider()
                    PreferencesRow(
                        String(localized: "settings.advanced.gh.trusted", defaultValue: "Trusted gh, owned by \(owner.displayName)")
                    ) {
                        PreferencesValue(text: trusted.path, isMonospaced: true)
                        Button(String(localized: "settings.advanced.gh.revoke", defaultValue: "Revoke")) {
                            Task { await viewModel.revokeTrustedGH() }
                        }
                        .fxButtonStyle(.outline, size: .compact)
                        .help(String(
                            localized: "settings.advanced.gh.revoke.help",
                            defaultValue: "Stop running this gh. FX Vault asks again the next time it finds it."
                        ))
                    }
                }
            }
            PreferencesSection(String(localized: "settings.advanced.vault.section", defaultValue: "Vault")) {
                PreferencesRow(String(localized: "settings.advanced.vault.folder", defaultValue: "Vault folder")) {
                    Button(String(localized: "settings.advanced.vault.revealShort", defaultValue: "Reveal in Finder")) {
                        if let url = viewModel.vaultFolderURL {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .fxButtonStyle(.outline, size: .compact)
                    .disabled(viewModel.vaultFolderURL == nil)
                }
                HairlineDivider()
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
        .sheet(isPresented: $viewModel.isShowingResetVault) {
            ResetVaultSheet(viewModel: viewModel)
        }
    }

    private var overrideLabel: String {
        String(localized: "settings.advanced.gh.override", defaultValue: "gh path override")
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

/// The gh in use as the board writes it ("gh 2.102.0 · /opt/homebrew/bin/gh"), or a spinner
/// while FX Vault looks. Any other state is a sentence under the row (``GHStatusRow``).
private struct GHInUseValue: View {
    let status: GHStatusModel

    var body: some View {
        switch status {
        case .ready(let version, let path):
            HStack(spacing: Theme.Spacing.xSmall) {
                PreferencesValue(text: String(localized: "settings.advanced.gh.inUse.version", defaultValue: "gh \(version) ·"))
                    .fixedSize()
                PreferencesValue(text: path, isMonospaced: true)
            }
            .accessibilityElement(children: .combine)
        case .checking:
            ProgressView()
                .controlSize(.small)
        default:
            EmptyView()
        }
    }

    static func needsSentence(_ status: GHStatusModel) -> Bool {
        switch status {
        case .ready, .checking, .unknown: false
        default: true
        }
    }
}

/// Reset vault (board Reset-Confirm): master password plus typing "reset" (D30). The final
/// confirm is the one danger-filled button.
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
            field(String(localized: "settings.reset.password", defaultValue: "Master password")) {
                SecureField(text: $viewModel.resetPassword) {
                    Text(String(localized: "settings.reset.password", defaultValue: "Master password"))
                }
                .textContentType(.password)
                .focused($focusedField, equals: .password)
                .fxInputField(.dialog, isFocused: focusedField == .password, isMonospaced: true)
            }
            field(confirmLabel) {
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

    /// An 11 pt label over its 28 pt field; the field carries the label for VoiceOver.
    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Layout.dialogNoteSpacing) {
            Text(label)
                .fxTextStyle(.formLabel)
                .foregroundStyle(Theme.Colors.subtleText)
                .accessibilityHidden(true)
            content()
        }
    }
}
