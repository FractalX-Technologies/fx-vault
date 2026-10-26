import AppKit

/// The open panel of Add file secret (1.0 F1). View-only: the view model receives the chosen
/// URL, so its tests never show a panel.
enum FileSecretPanels {
    /// Asks for any file (drag and drop takes .p8, .pem and .json only). Hidden files are shown:
    /// keys often live in dotfolders. Returns nil when the user cancels.
    static func chooseFile() -> URL? {
        #if FXVAULT_UI_TESTING
        // XCUITest cannot drive an open panel reliably: the UITesting host picks its fixture.
        return UITestFileSecret.chooseFile()
        #else
        let panel = NSOpenPanel()
        panel.title = String(localized: "fileSecret.panel.title", defaultValue: "Add File Secret")
        panel.prompt = String(localized: "fileSecret.panel.prompt", defaultValue: "Choose")
        panel.message = String(
            localized: "fileSecret.panel.message",
            defaultValue: "Choose the file to store as a secret. FX Vault reads it; the file is not changed."
        )
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
        #endif
    }
}
