import AppKit
import SwiftUI

/// Preferences › General: clone folder, the name for nearby Macs and auto-lock (works in every
/// phase).
struct GeneralSettingsView: View {
    @Bindable var viewModel: PreferencesViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "settings.general.cloneFolder", defaultValue: "Clone folder")) {
                    HStack {
                        Text(verbatim: viewModel.cloneFolderURL?.path(percentEncoded: false)
                            ?? String(localized: "settings.general.cloneFolder.none", defaultValue: "Not chosen"))
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(String(localized: "settings.general.cloneFolder.choose", defaultValue: "Choose…")) {
                            chooseCloneFolder()
                        }
                    }
                }
            }
            Section {
                TextField(
                    String(localized: "settings.general.nearbyName", defaultValue: "Name for nearby Macs"),
                    text: $viewModel.nearbyDisplayName,
                    prompt: Text(verbatim: viewModel.defaultNearbyDisplayName)
                )
                Text(String(
                    localized: "settings.general.nearbyName.note",
                    defaultValue: "Shown to nearby Macs while Nearby Chat is open, and to the teammate you share with nearby. Anyone nearby can see it, and it proves nothing: compare the code to know who you're talking to."
                ))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            }
            Section {
                Picker(
                    String(localized: "settings.general.autoLock", defaultValue: "Lock after inactivity"),
                    selection: $viewModel.autoLockMinutes
                ) {
                    ForEach(viewModel.autoLockOptions, id: \.self) { minutes in
                        Text(String(localized: "settings.general.autoLock.minutes", defaultValue: "\(minutes) min"))
                            .tag(minutes)
                    }
                }
                Text(String(
                    localized: "settings.general.autoLock.note",
                    defaultValue: "FX Vault always locks when your Mac sleeps, the screen locks or the window closes. The inactivity timer pauses while a sync runs."
                ))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .formStyle(.grouped)
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
