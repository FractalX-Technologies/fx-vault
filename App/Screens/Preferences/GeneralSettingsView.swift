import AppKit
import SwiftUI

/// Preferences › General: clone folder and auto-lock (works in every phase), as hairline groups (docs/DESIGN.md, "Settings").
struct GeneralSettingsView: View {
    @Bindable var viewModel: PreferencesViewModel

    var body: some View {
        PreferencesPage {
            PreferencesSection(String(localized: "settings.general.repositories.section", defaultValue: "Repositories")) {
                PreferencesRow(
                    String(localized: "settings.general.cloneFolder", defaultValue: "Clone folder"),
                    detail: viewModel.cloneFolderURL?.path(percentEncoded: false)
                        ?? String(localized: "settings.general.cloneFolder.none", defaultValue: "Not chosen"),
                    isDetailMonospaced: viewModel.cloneFolderURL != nil
                ) {
                    Button(String(localized: "settings.general.cloneFolder.choose", defaultValue: "Choose…")) {
                        chooseCloneFolder()
                    }
                    .fxButtonStyle(.secondary)
                }
            }
            PreferencesSection(
                String(localized: "settings.general.autoLock.section", defaultValue: "Auto-lock"),
                footnote: String(
                    localized: "settings.general.autoLock.note",
                    defaultValue: "FX Vault always locks when your Mac sleeps, the screen locks or the window closes. The inactivity timer pauses while a sync runs."
                )
            ) {
                PreferencesRow(String(localized: "settings.general.autoLock", defaultValue: "Lock after inactivity")) {
                    Picker(
                        String(localized: "settings.general.autoLock", defaultValue: "Lock after inactivity"),
                        selection: $viewModel.autoLockMinutes
                    ) {
                        ForEach(viewModel.autoLockOptions, id: \.self) { minutes in
                            Text(String(localized: "settings.general.autoLock.minutes", defaultValue: "\(minutes) min"))
                                .tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
        }
    }

    private func chooseCloneFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = viewModel.cloneFolderURL
        panel.prompt = String(localized: "settings.general.cloneFolder.prompt", defaultValue: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.setCloneFolder(url)
    }
}
