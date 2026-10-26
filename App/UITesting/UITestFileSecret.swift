#if FXVAULT_UI_TESTING
import Foundation

/// The file the UITesting host's Choose… picks in Add file secret (1.0 F1): written fresh on
/// each call into the UI-test folder, synthetic text with three lines and a trailing line break.
enum UITestFileSecret {
    static let fileName = "AuthKey_FIXTURE01.p8"
    static let text = "-----BEGIN FIXTURE-----\nFXV_FIXTURE_FILE_SECRET\n-----END FIXTURE-----\n"

    static func chooseFile(fileManager: FileManager = .default) -> URL? {
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent(UITestLaunch.runsDirectoryName, isDirectory: true)
            .appendingPathComponent("file-secret", isDirectory: true)
        let url = folder.appendingPathComponent(fileName)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return url
    }
}
#endif
