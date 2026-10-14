import Foundation
import Testing
@testable import EnvTools

@Suite("CloudSyncDetector")
struct CloudSyncDetectorTests {
    /// A fake home with the iCloud folders, removed by the caller.
    private struct FakeHome {
        let root: URL

        init() throws {
            root = try TestValues.makeTemporaryDirectory()
            for folder in ["Library/Mobile Documents/com~apple~CloudDocs", "Desktop", "Documents", "Projects"] {
                try FileManager.default.createDirectory(
                    at: root.appending(path: folder, directoryHint: .isDirectory),
                    withIntermediateDirectories: true
                )
            }
        }

        func url(_ path: String) -> URL {
            root.appending(path: path)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A probe that reports ubiquitous for the given folder names under `home` (resolved paths).
    private func probe(home: FakeHome, ubiquitous folders: Set<String>) -> @Sendable (URL) -> Bool {
        let paths = Set(folders.map { PathResolver.resolvedPath(of: home.url($0)) })
        return { url in paths.contains(PathResolver.resolvedPath(of: url)) }
    }

    @Test func iCloudDriveFolder() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let detector = CloudSyncDetector(homeDirectory: home.root, isUbiquitous: { _ in false })
        let file = home.url("Library/Mobile Documents/com~apple~CloudDocs/app/.env")
        #expect(detector.status(for: file) == .iCloudDrive)
        #expect(detector.status(for: file).isSyncedToICloud)
    }

    @Test func desktopAndDocumentsWhenSyncIsOn() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let detector = CloudSyncDetector(
            homeDirectory: home.root,
            isUbiquitous: probe(home: home, ubiquitous: ["Desktop", "Documents"])
        )
        #expect(detector.status(for: home.url("Desktop/.env")) == .iCloudDesktopAndDocuments)
        #expect(detector.status(for: home.url("Documents/new/folder/.env")) == .iCloudDesktopAndDocuments)
        #expect(detector.status(for: home.url("Projects/.env")) == .notSynced)
    }

    @Test func desktopAndDocumentsWhenSyncIsOff() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let detector = CloudSyncDetector(homeDirectory: home.root, isUbiquitous: { _ in false })
        #expect(detector.status(for: home.url("Desktop/.env")) == .notSynced)
        #expect(detector.status(for: home.url("Documents/.env")) == .notSynced)
        #expect(!CloudSyncStatus.notSynced.isSyncedToICloud)
    }

    @Test func otherUbiquitousFoldersUseTheNearestExistingAncestor() throws {
        let home = try FakeHome()
        defer { home.remove() }
        try FileManager.default.createDirectory(at: home.url("Projects/Synced"), withIntermediateDirectories: true)
        let detector = CloudSyncDetector(
            homeDirectory: home.root,
            isUbiquitous: probe(home: home, ubiquitous: ["Projects/Synced"])
        )
        #expect(detector.status(for: home.url("Projects/Synced/.env")) == .iCloudDrive)
        #expect(detector.status(for: home.url("Projects/Other/.env")) == .notSynced)
    }

    @Test func symbolicLinksIntoICloudAreResolved() throws {
        let home = try FakeHome()
        defer { home.remove() }
        try FileManager.default.createSymbolicLink(
            at: home.url("Projects/cloud"),
            withDestinationURL: home.url("Library/Mobile Documents/com~apple~CloudDocs")
        )
        let detector = CloudSyncDetector(homeDirectory: home.root, isUbiquitous: { _ in false })
        #expect(detector.status(for: home.url("Projects/cloud/app/.env")) == .iCloudDrive)
    }

    @Test func pathComparisonIsCaseInsensitive() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let detector = CloudSyncDetector(homeDirectory: home.root, isUbiquitous: { _ in false })
        #expect(detector.status(for: home.url("library/mobile documents/x/.env")) == .iCloudDrive)
    }

    @Test func liveProbeOnATemporaryFolder() throws {
        let directory = try TestValues.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The temporary folder is never in iCloud; this checks the live probe runs cleanly.
        #expect(CloudSyncDetector().status(for: directory.appending(path: ".env")) == .notSynced)
    }
}
