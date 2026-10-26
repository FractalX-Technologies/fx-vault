import AppKit
import SwiftUI
import VaultCore

/// Preferences › General (board Settings-General): auto-lock, then the clipboard and the clone
/// folder. It works in every phase.
struct GeneralSettingsView: View {
    @Bindable var viewModel: PreferencesViewModel

    var body: some View {
        PreferencesPage {
            PreferencesSection(
                String(localized: "settings.general.lock.section", defaultValue: "Lock"),
                footnote: String(
                    localized: "settings.general.autoLock.note",
                    defaultValue: "FX Vault always locks when your Mac sleeps, the screen locks or the window closes. The inactivity timer pauses while a sync runs."
                )
            ) {
                PreferencesRow(autoLockLabel) {
                    DialogPopUp(
                        title: autoLockLabel,
                        selection: $viewModel.autoLockMinutes,
                        options: viewModel.autoLockOptions.map { minutes in
                            .init(
                                value: minutes,
                                title: String(localized: "settings.general.autoLock.minutes", defaultValue: "\(minutes) min")
                            )
                        }
                    )
                    .frame(width: Theme.Layout.settingsPopUpWidth)
                }
            }
            PreferencesSection(nil) {
                PreferencesRow(
                    String(localized: "settings.general.clipboard", defaultValue: "Clipboard clears after"),
                    detail: String(
                        localized: "settings.general.clipboard.detail.lock",
                        defaultValue: "Also clears when FX Vault locks. Copied values stay on this Mac and are marked concealed; most clipboard managers skip them"
                    )
                ) {
                    PreferencesValue(text: String(
                        localized: "settings.general.clipboard.seconds",
                        defaultValue: "\(Timeouts.clipboardClear.wholeSeconds) s"
                    ))
                }
                HairlineDivider()
                PreferencesRow(String(localized: "settings.general.cloneFolder", defaultValue: "Clone folder")) {
                    PreferencesValue(text: cloneFolder)
                    Button(String(localized: "settings.general.cloneFolder.choose", defaultValue: "Choose…")) {
                        chooseCloneFolder()
                    }
                    .fxButtonStyle(.outline, size: .compact)
                }
            }
        }
    }

    private var autoLockLabel: String {
        String(localized: "settings.general.autoLock", defaultValue: "Lock after inactivity")
    }

    /// `~/Code`, as the board writes a folder in the home folder.
    private var cloneFolder: String {
        guard let url = viewModel.cloneFolderURL else {
            return String(localized: "settings.general.cloneFolder.none", defaultValue: "Not chosen")
        }
        return (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
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
