import AppKit
import SwiftUI
import VaultCore

/// Preferences › Advanced (board Settings-Advanced): the gh path override, the gh in use, the gh
/// trusted although another user owns it (with Revoke, v0.3.1), the telemetry note, Copy
/// Diagnostics and the vault folder. It works in every phase (docs/DESIGN.md, "Settings").
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
                if viewModel.ghStatus.needsInUseSentence {
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
            PreferencesSection(String(localized: "settings.advanced.diagnostics.section", defaultValue: "Diagnostics")) {
                PreferencesRow(
                    String(localized: "ghSetup.copyDiagnostics", defaultValue: "Copy Diagnostics"),
                    detail: String(
                        localized: "settings.advanced.diagnostics.detail.names",
                        defaultValue: "Versions, paths and checks · variable names and account names only"
                    )
                ) {
                    Button {
                        Task { await viewModel.copyDiagnostics() }
                    } label: {
                        if viewModel.hasCopiedDiagnostics {
                            Label(String(localized: "settings.advanced.diagnostics.copied", defaultValue: "Copied"), systemImage: "checkmark")
                        } else {
                            Label(String(localized: "command.copy", defaultValue: "Copy"), systemImage: "doc.on.doc")
                        }
                    }
                    .fxButtonStyle(.outline, size: .compact)
                    .disabled(viewModel.isCollectingDiagnostics)
                    .help(String(
                        localized: "ghSetup.copyDiagnostics.help",
                        defaultValue: "Copy a report of which gh FX Vault found and why, for support. It contains no tokens or values."
                    ))
                }
                HairlineDivider()
                // The full JSON report (Touch ID readiness too). It names the executable:
                // `open -a … --args` would print nowhere.
                PreferencesBlock(spacing: Theme.Spacing.smallMinus) {
                    Text(String(localized: "settings.advanced.diagnostics.terminal", defaultValue: "From Terminal:"))
                        .fxTextStyle(.formNote)
                        .foregroundStyle(Theme.Colors.subtleText)
                    CommandRow(command: DiagnoseCommand.terminalCommand()) { viewModel.copyCommand($0) }
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
                    .accessibilityIdentifier(AccessibilityID.Settings.revealVaultFolder)
                }
            }
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
        if let inUse = status.inUse {
            HStack(spacing: Theme.Spacing.xSmall) {
                PreferencesValue(text: String(localized: "settings.advanced.gh.inUse.version", defaultValue: "gh \(inUse.version) ·"))
                    .fixedSize()
                PreferencesValue(text: inUse.path, isMonospaced: true)
            }
            .accessibilityElement(children: .combine)
        } else if status == .checking {
            ProgressView()
                .controlSize(.small)
        }
    }
}

extension GHStatusModel {
    /// The version and path of a ready gh (Settings › Advanced, In use).
    var inUse: (version: String, path: String)? {
        if case .ready(let version, let path) = self { (version, path) } else { nil }
    }

    /// True when the In use row needs ``GHStatusRow``'s sentence under it: every state but ready,
    /// checking and unknown. Unknown means detection has not run (previews, tests): the row then
    /// shows the requirement and Check Again only, as ``GHStatusRow`` shows nothing for it.
    var needsInUseSentence: Bool {
        switch self {
        case .ready, .checking, .unknown: false
        default: true
        }
    }
}
