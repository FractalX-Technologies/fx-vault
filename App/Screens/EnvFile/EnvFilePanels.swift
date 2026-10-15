import AppKit
import UniformTypeIdentifiers

/// The open and save panels of the `.env` sheets. View-only: view models receive the chosen URL,
/// so tests never show a panel.
enum EnvFilePanels {
    /// The default name of an exported file.
    static let defaultExportFileName = ".env"

    /// Asks for a `.env` file to import. Hidden files are shown, because `.env` files are
    /// dotfiles. Returns nil when the user cancels.
    static func chooseImportFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "envImport.panel.title", defaultValue: "Import .env")
        panel.prompt = String(localized: "envImport.panel.prompt", defaultValue: "Choose")
        panel.message = String(
            localized: "envImport.panel.message",
            defaultValue: "Choose a .env file. Its values are read into FX Vault; the file is not changed."
        )
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Asks where to write the plaintext export. The panel itself confirms replacing an existing
    /// file. Returns nil when the user cancels.
    static func chooseExportDestination(fileName: String, directory: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "envExport.panel.title", defaultValue: "Export .env")
        panel.prompt = String(localized: "envExport.panel.prompt", defaultValue: "Export")
        panel.message = String(
            localized: "envExport.panel.message",
            defaultValue: "The file will contain plaintext values. Choose a folder that is not synced or committed."
        )
        panel.nameFieldStringValue = fileName
        panel.showsHiddenFiles = true
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = true
        if let directory {
            panel.directoryURL = directory
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
