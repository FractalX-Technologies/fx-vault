import AppKit

/// The clone destination (§10: "Clone to my Mac"): the folder from Preferences › General, or one
/// chosen now with an open panel (then remembered).
enum ClonePanel {
    static func folder(for main: MainViewModel) -> URL? {
        folder(preferences: main.app.container.preferences)
    }

    /// The clone folder from Preferences, or one chosen now (saved to Preferences); nil when the
    /// panel is cancelled. Features without a `MainViewModel` (the Sync result) call this one.
    static func folder(preferences: PreferencesManager) -> URL? {
        if let folder = preferences.cloneFolderURL {
            return folder
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "main.clone.choose", defaultValue: "Clone Here")
        panel.message = String(
            localized: "main.clone.message",
            defaultValue: "Choose the folder FX Vault clones repositories into. You can change it in Settings › General."
        )
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        preferences.setCloneFolder(url)
        return url
    }
}
