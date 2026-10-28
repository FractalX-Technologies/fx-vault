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

/// The files the UITesting host's Add File… picks and where its Save As… writes (v23): the file
/// the test names in ``UITestEnvironment/folderFileName`` and ``UITestEnvironment/folderFileText``,
/// written fresh in the UI-test folder, and a `saved` folder next to it that the test reads back.
enum UITestFolderFile {
    static func chooseFiles(fileManager: FileManager = .default) -> [URL] {
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment[UITestEnvironment.folderFileName], let text = environment[UITestEnvironment.folderFileText] else {
            return []
        }
        let saved = savedFolder(fileManager)
        let url = saved.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try fileManager.createDirectory(at: saved, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            preconditionFailure("The UI-test folder file could not be written: \(error)")
        }
        return [url]
    }

    static func destination(fileName: String, fileManager: FileManager = .default) -> URL? {
        let saved = savedFolder(fileManager)
        do {
            try fileManager.createDirectory(at: saved, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            preconditionFailure("The UI-test save folder could not be created: \(error)")
        }
        return saved.appendingPathComponent(fileName)
    }

    private static func savedFolder(_ fileManager: FileManager) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(UITestEnvironment.folderFileSavedPath, isDirectory: true)
    }
}
#endif
