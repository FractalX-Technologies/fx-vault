import Foundation
import Testing
@testable import EnvTools

@Suite("GitignoreEditor")
struct GitignoreEditorTests {
    @Test(
        "ignore line",
        arguments: [
            (".env", "/.env" as String?),
            ("config/.env.production", "/config/.env.production"),
            ("a*b?.env", #"/a\*b\?.env"#),
            ("[x].env", #"/\[x].env"#),
            (#"back\slash"#, #"/back\\slash"#),
            ("trail  ", #"/trail\ \ "#),
            ("#hash", "/#hash"),
            ("!bang", "/!bang"),
            ("a\nb", nil),
            ("", nil),
        ]
    )
    func ignoreLine(path: String, expected: String?) {
        #expect(GitignoreEditor.ignoreLine(forRelativePath: path) == expected)
    }

    @Test(
        "contains entry for .env",
        arguments: [
            ("/.env\n", true),
            (".env\n", true),
            ("**/.env\n", true),
            ("/.env   \n", true),
            ("/.env\r\n", true),
            ("node_modules\n/.env", true),
            ("# /.env\n", false),
            ("!/.env\n", false),
            ("/.env.local\n", false),
            ("*.env\n", false),
            ("", false),
        ]
    )
    func containsEntryAtRoot(contents: String, expected: Bool) {
        #expect(GitignoreEditor.containsEntry(forRelativePath: ".env", in: contents) == expected)
    }

    @Test func containsEntryInSubfolder() {
        #expect(GitignoreEditor.containsEntry(forRelativePath: "config/.env", in: "config/.env\n"))
        #expect(GitignoreEditor.containsEntry(forRelativePath: "config/.env", in: "/config/.env\n"))
        #expect(!GitignoreEditor.containsEntry(forRelativePath: "config/.env", in: ".env\n"))
    }

    @Test func escapedTrailingSpaceIsKept() {
        #expect(GitignoreEditor.containsEntry(forRelativePath: "trail ", in: "/trail\\ \n"))
    }

    @Test func addingEntries() {
        #expect(GitignoreEditor.contents(byAddingEntryForRelativePath: ".env", to: nil) == "/.env\n")
        #expect(GitignoreEditor.contents(byAddingEntryForRelativePath: ".env", to: "") == "/.env\n")
        #expect(
            GitignoreEditor.contents(byAddingEntryForRelativePath: ".env", to: "node_modules\n")
                == "node_modules\n/.env\n"
        )
        #expect(
            GitignoreEditor.contents(byAddingEntryForRelativePath: ".env", to: "node_modules")
                == "node_modules\n/.env\n"
        )
        #expect(GitignoreEditor.contents(byAddingEntryForRelativePath: ".env", to: "/.env\n") == nil)
        #expect(GitignoreEditor.contents(byAddingEntryForRelativePath: "a\nb", to: "") == nil)
    }

    @Test func entryIsAddedAgainAfterALaterNegation() {
        let existing = "/.env\n!/.env\n"
        #expect(
            GitignoreEditor.contents(byAddingEntryForRelativePath: ".env", to: existing)
                == "/.env\n!/.env\n/.env\n"
        )
    }

    @Test func relativePaths() throws {
        let root = try TestValues.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "config"), withIntermediateDirectories: true)

        #expect(GitignoreEditor.relativePath(of: root.appending(path: ".env"), toRepositoryRoot: root) == ".env")
        #expect(
            GitignoreEditor.relativePath(of: root.appending(path: "config/.env.prod"), toRepositoryRoot: root)
                == "config/.env.prod"
        )
        #expect(
            GitignoreEditor.relativePath(of: root.appending(path: "new/dir/.env"), toRepositoryRoot: root)
                == "new/dir/.env"
        )
        #expect(GitignoreEditor.relativePath(of: root, toRepositoryRoot: root) == nil)
        #expect(
            GitignoreEditor.relativePath(of: root.deletingLastPathComponent().appending(path: ".env"), toRepositoryRoot: root)
                == nil
        )
        #expect(GitignoreEditor.gitignoreURL(repositoryRoot: root).lastPathComponent == ".gitignore")
    }

    @Test func relativePathMatchesAResolvedRoot() throws {
        // The temporary folder lives under /var, a link to /private/var; git prints the
        // resolved root.
        let root = try TestValues.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolvedRoot = URL(filePath: PathResolver.resolvedPath(of: root), directoryHint: .isDirectory)
        #expect(GitignoreEditor.relativePath(of: root.appending(path: ".env"), toRepositoryRoot: resolvedRoot) == ".env")
    }
}

/// A scripted ``GitignoreChecker``.
private struct FakeGitignoreChecker: GitignoreChecker {
    struct Failure: Error, Equatable {}

    var root: URL?
    var ignored: Set<String> = []
    var tracked: Set<String> = []
    var failsOnIgnoreCheck = false

    func repositoryRoot(containing directory: URL) async throws -> URL? {
        root
    }

    func isIgnored(relativePath: String, inRepositoryAt root: URL) async throws -> Bool {
        if failsOnIgnoreCheck { throw Failure() }
        return ignored.contains(relativePath)
    }

    func isTracked(relativePath: String, inRepositoryAt root: URL) async throws -> Bool {
        tracked.contains(relativePath)
    }
}

@Suite("GitExposureInspector")
struct GitExposureInspectorTests {
    @Test func outsideARepository() async throws {
        let root = try TestValues.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exposure = try await GitExposureInspector.inspect(
            fileURL: root.appending(path: ".env"),
            using: FakeGitignoreChecker(root: nil)
        )
        #expect(exposure == .outsideRepository)
        #expect(!exposure.isExposed)
    }

    @Test func ignoredFile() async throws {
        let root = try TestValues.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exposure = try await GitExposureInspector.inspect(
            fileURL: root.appending(path: ".env"),
            using: FakeGitignoreChecker(root: root, ignored: [".env"])
        )
        #expect(exposure == .ignored(repositoryRoot: root, relativePath: ".env"))
        #expect(!exposure.isExposed)
    }

    @Test func notIgnoredFileGetsASuggestedLine() async throws {
        let root = try TestValues.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exposure = try await GitExposureInspector.inspect(
            fileURL: root.appending(path: "config/.env"),
            using: FakeGitignoreChecker(root: root)
        )
        #expect(exposure == .notIgnored(repositoryRoot: root, relativePath: "config/.env", suggestedIgnoreLine: "/config/.env"))
        #expect(exposure.isExposed)
    }

    @Test func trackedWinsOverIgnored() async throws {
        let root = try TestValues.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exposure = try await GitExposureInspector.inspect(
            fileURL: root.appending(path: ".env"),
            using: FakeGitignoreChecker(root: root, ignored: [".env"], tracked: [".env"])
        )
        #expect(exposure == .tracked(repositoryRoot: root, relativePath: ".env"))
        #expect(exposure.isExposed)
    }

    @Test func fileOutsideTheReportedRoot() async throws {
        let root = try TestValues.makeTemporaryDirectory()
        let other = try TestValues.makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: other)
        }
        let exposure = try await GitExposureInspector.inspect(
            fileURL: other.appending(path: ".env"),
            using: FakeGitignoreChecker(root: root)
        )
        #expect(exposure == .outsideRepository)
    }

    @Test func checkerErrorsArePassedOn() async throws {
        let root = try TestValues.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: FakeGitignoreChecker.Failure()) {
            try await GitExposureInspector.inspect(
                fileURL: root.appending(path: ".env"),
                using: FakeGitignoreChecker(root: root, failsOnIgnoreCheck: true)
            )
        }
    }
}
