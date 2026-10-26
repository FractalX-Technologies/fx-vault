import AppKit
import SwiftUI
import VaultCore

/// Preferences › General (board Settings-General): the quick vault shortcut and Open at login,
/// then the locks, then the clipboard, sound effects and the clone folder. It works in every
/// phase.
struct GeneralSettingsView: View {
    @Bindable var viewModel: PreferencesViewModel

    var body: some View {
        let opensAtLogin = Binding(
            get: { viewModel.opensAtLogin },
            set: { viewModel.setOpensAtLogin($0) }
        )
        PreferencesPage {
            PreferencesSection(nil) {
                PreferencesRow(
                    shortcutLabel,
                    detail: String(localized: "settings.general.quickVault.detail", defaultValue: "Opens the quick vault from the notch")
                ) {
                    QuickVaultShortcutRecorder(title: shortcutLabel, shortcut: $viewModel.quickVaultShortcut)
                        .frame(width: Theme.Layout.settingsPopUpWidth)
                        .accessibilityIdentifier(AccessibilityID.Settings.quickVaultShortcut)
                }
                HairlineDivider()
                PreferencesRow(openAtLoginLabel, detail: openAtLoginDetail) {
                    if viewModel.loginItemStatus == .needsApproval {
                        Button(String(localized: "settings.general.openAtLogin.openSettings", defaultValue: "Open Login Items")) {
                            viewModel.openLoginItemsSettings()
                        }
                        .fxButtonStyle(.outline, size: .compact)
                    }
                    Toggle(openAtLoginLabel, isOn: opensAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                if let error = viewModel.loginItemError {
                    HairlineDivider()
                    PreferencesBlock {
                        InlineErrorView(error: error)
                    }
                }
            }
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
                HairlineDivider()
                PreferencesRow(screenLockLabel) {
                    // FX Vault always locks with the screen: the switch only says so.
                    Toggle(screenLockLabel, isOn: .constant(true))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(true)
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
                PreferencesRow(String(localized: "settings.general.sounds", defaultValue: "Sound effects")) {
                    PreferencesValue(text: String(localized: "settings.general.sounds.value", defaultValue: "Follows system"))
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
        .onAppear {
            viewModel.refreshLoginItem()
        }
    }

    private var shortcutLabel: String {
        String(localized: "settings.general.quickVault", defaultValue: "Quick vault shortcut")
    }

    private var openAtLoginLabel: String {
        String(localized: "settings.general.openAtLogin", defaultValue: "Open at login")
    }

    private var openAtLoginDetail: String? {
        guard viewModel.loginItemStatus == .needsApproval else { return nil }
        return String(
            localized: "settings.general.openAtLogin.needsApproval",
            defaultValue: "Allow FX Vault in System Settings › General › Login Items"
        )
    }

    private var screenLockLabel: String {
        String(localized: "settings.general.screenLock", defaultValue: "Lock when the screen locks")
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
