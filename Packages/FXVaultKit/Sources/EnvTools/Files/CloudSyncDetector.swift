import Foundation

/// Whether a location syncs to iCloud (§5.13). Any synced status shows the explicit "This folder
/// syncs to iCloud" warning, which also notes that Spotlight indexes the file.
public enum CloudSyncStatus: Sendable, Hashable {
    /// Not in a folder known to sync to iCloud.
    case notSynced
    /// In iCloud Drive (`~/Library/Mobile Documents`) or another ubiquitous location.
    case iCloudDrive
    /// In `~/Desktop` or `~/Documents` while iCloud "Desktop & Documents Folders" is on.
    case iCloudDesktopAndDocuments

    /// True for every status except ``notSynced``.
    public var isSyncedToICloud: Bool {
        self != .notSynced
    }
}

/// Detects iCloud-synced destinations before a plaintext export (§5.13).
///
/// Checks, in order:
/// 1. the path is under `~/Library/Mobile Documents` → ``CloudSyncStatus/iCloudDrive``;
/// 2. the path is under `~/Desktop` or `~/Documents` and that folder is ubiquitous (iCloud
///    Desktop & Documents is on) → ``CloudSyncStatus/iCloudDesktopAndDocuments``;
/// 3. the file, or its nearest existing ancestor, reports `isUbiquitousItem` →
///    ``CloudSyncStatus/iCloudDrive``.
///
/// Symbolic links are resolved first, so a link into iCloud Drive is caught.
public struct CloudSyncDetector: Sendable {
    private static let mobileDocumentsPath = "Library/Mobile Documents"
    private static let desktopAndDocumentsFolders = ["Desktop", "Documents"]

    private let homeDirectory: URL
    private let isUbiquitous: @Sendable (URL) -> Bool

    /// - Parameters:
    ///   - homeDirectory: the user's home folder (injected in tests).
    ///   - isUbiquitous: reads `URLResourceValues.isUbiquitousItem` (injected in tests).
    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        isUbiquitous: @escaping @Sendable (URL) -> Bool = CloudSyncDetector.systemIsUbiquitous
    ) {
        self.homeDirectory = homeDirectory
        self.isUbiquitous = isUbiquitous
    }

    /// The iCloud status of `fileURL` (which need not exist yet).
    public func status(for fileURL: URL) -> CloudSyncStatus {
        let path = PathResolver.resolvedPath(of: fileURL)
        let home = PathResolver.resolvedPath(of: homeDirectory)

        let mobileDocuments = (home as NSString).appendingPathComponent(Self.mobileDocumentsPath)
        if PathResolver.isPath(path, within: mobileDocuments) {
            return .iCloudDrive
        }
        for folder in Self.desktopAndDocumentsFolders {
            let folderPath = (home as NSString).appendingPathComponent(folder)
            if PathResolver.isPath(path, within: folderPath),
               isUbiquitous(URL(filePath: folderPath, directoryHint: .isDirectory)) {
                return .iCloudDesktopAndDocuments
            }
        }
        let resolvedURL = URL(filePath: path)
        if let existing = PathResolver.nearestExistingURL(of: resolvedURL), isUbiquitous(existing) {
            return .iCloudDrive
        }
        return .notSynced
    }

    /// The live probe: `URLResourceValues.isUbiquitousItem`, false when it cannot be read.
    public static let systemIsUbiquitous: @Sendable (URL) -> Bool = { url in
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false
    }
}
