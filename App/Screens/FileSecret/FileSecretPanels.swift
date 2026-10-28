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

/// The panels of a folder's Files section (v23). View-only: the view model receives the URLs.
enum FolderFilePanels {
    /// Asks for files to keep in the folder. Hidden files are shown. Empty when the user cancels.
    static func chooseFiles() -> [URL] {
        #if FXVAULT_UI_TESTING
        // XCUITest cannot drive an open panel reliably: the UITesting host picks its fixture.
        return UITestFolderFile.chooseFiles()
        #else
        let panel = NSOpenPanel()
        panel.title = String(localized: "folderFile.panel.add.title", defaultValue: "Add Files")
        panel.prompt = String(localized: "folderFile.panel.add.prompt", defaultValue: "Add")
        panel.message = String(
            localized: "folderFile.panel.add.message",
            defaultValue: "Choose files up to \(FolderFileCopy.limit()) each. FX Vault keeps an encrypted copy; the files are not changed."
        )
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
        #endif
    }

    /// Asks where to save a file. The panel itself confirms replacing an existing file. Nil when
    /// the user cancels.
    static func chooseDestination(fileName: String) -> URL? {
        #if FXVAULT_UI_TESTING
        return UITestFolderFile.destination(fileName: fileName)
        #else
        let panel = NSSavePanel()
        panel.title = FolderFileCopy.saveTitle(fileName)
        panel.prompt = String(localized: "folderFile.panel.save.prompt", defaultValue: "Save")
        panel.message = String(
            localized: "folderFile.panel.save.message",
            defaultValue: "The file is saved unencrypted. Choose a folder that is not synced or shared if it is sensitive."
        )
        panel.nameFieldStringValue = fileName
        panel.showsHiddenFiles = true
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
        #endif
    }
}
