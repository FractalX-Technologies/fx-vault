import Foundation

/// A private folder (mode 0700) under the temporary directory that holds one export's
/// encrypted `.fxvault` file until it is saved or sent (§9.1 writer). The file itself is
/// written 0600 by `SecureFileWriter`; it is ciphertext only and is removed when the sheet
/// closes (or when a running AirDrop hand-off finishes).
final class ShareStagingFolder {
    let url: URL

    /// Owner read, write and search only.
    private static let folderMode = 0o700
    private static let rootName = "io.fractalx.fxvault.shares"

    /// `$TMPDIR/io.fractalx.fxvault.shares` (per user).
    static var defaultRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(rootName, isDirectory: true)
    }

    init(root: URL = ShareStagingFolder.defaultRoot) throws {
        let fileManager = FileManager.default
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: Self.folderMode]
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: attributes)
        try fileManager.setAttributes(attributes, ofItemAtPath: root.path)
        url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false, attributes: attributes)
    }

    /// The staged file named `name` inside the folder.
    func fileURL(named name: String) -> URL {
        url.appendingPathComponent(name, isDirectory: false)
    }

    /// Removes the folder and the staged file. Idempotent.
    func remove() {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            AppLog.ui.error("Removing a staged share file failed")
        }
    }
}
