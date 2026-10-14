import Darwin
import Foundation
import Testing
@testable import GitHubKit
import VaultCore

/// Sanitized fixtures in `Tests/GitHubKitTests/Fixtures` (tasks/todo.md §12.4).
enum Fixture {
    struct Missing: Error {
        let path: String
    }

    static func url(_ path: String) throws -> URL {
        guard let root = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            throw Missing(path: "Fixtures")
        }
        let url = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw Missing(path: path) }
        return url
    }

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: url(path))
    }

    static func string(_ path: String) throws -> String {
        String(decoding: try data(path), as: UTF8.self)
    }
}

enum TestValues {
    static let identity = ProcessIdentityModel(
        home: "/Users/user-a",
        user: "user-a",
        temporaryDirectory: "/private/tmp/fxvault-tests",
        sshAuthSocket: "/private/tmp/agent.sock"
    )
    static let shell = ShellEnvironmentModel(path: "/opt/homebrew/bin:/usr/bin:/bin")
    static let ghURL = URL(fileURLWithPath: "/nonexistent/fxvault-tests/gh")
    static let workingDirectory = URL(fileURLWithPath: "/private/tmp/fxvault-tests/empty-cwd", isDirectory: true)
    /// Synthetic token-shaped strings, assembled at runtime so no token literal is in source.
    static let token = syntheticToken(filler: "0")
    static let otherToken = syntheticToken(filler: "1")

    private static func syntheticToken(filler: Character) -> String {
        ["gho", "FIXTURE" + String(repeating: filler, count: 30)].joined(separator: "_")
    }

    static func repo(_ owner: String = "owner-a", _ name: String = "repo-a") throws -> GHRepoRef {
        try GHRepoRef(owner: owner, name: name)
    }

    static func service(_ runner: any CommandRunning) -> GHCommandService {
        GHCommandService(
            executableURL: ghURL,
            identity: identity,
            shell: shell,
            workingDirectory: workingDirectory,
            runner: runner
        )
    }

    static func secret(_ text: String) -> SecretBytes {
        SecretBytes(utf8: text)
    }
}

/// A temporary directory removed when the value is deinitialized.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("fxvault-githubkit-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolve /var → /private/var with realpath (Foundation's resolvingSymlinksInPath strips
        // /private) so path comparisons match what child processes report.
        guard let resolved = realpath(base.path, nil) else { throw Fixture.Missing(path: base.path) }
        url = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        free(resolved)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String, contents: String = "", mode: Int16 = 0o755) throws -> URL {
        let file = url.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        return file
    }
}

/// argv matchers for ``FakeCommandRunner``.
enum Match {
    static func prefix(_ prefix: [String]) -> FakeCommandRunner.Matcher {
        { Array($0.prefix(prefix.count)) == prefix }
    }

    static func contains(_ argument: String) -> FakeCommandRunner.Matcher {
        { $0.contains(argument) }
    }
}
