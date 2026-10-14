import Foundation
import Testing
@testable import GitHubKit
import VaultCore

@Suite("ProcessEnvironmentBuilder")
struct ProcessEnvironmentBuilderTests {
    typealias Key = ProcessEnvironmentBuilder.Key

    /// FX Vault's own environment full of forbidden and unrelated keys: none may leak.
    static let hostileProcessEnvironment: [String: String] = Dictionary(
        uniqueKeysWithValues: ProcessEnvironmentBuilder.forbiddenKeys.map { ($0, "1") }
            + [("SSH_AUTH_SOCK", "/private/tmp/launchd.sock"), ("AWS_SECRET_ACCESS_KEY", "x"), ("GH_TOKEN", "leak")]
    )

    @Test func ghEnvironmentIsExactlyTheAllowlist() throws {
        let identity = ProcessIdentityModel.current(processEnvironment: Self.hostileProcessEnvironment)
        let shell = ShellEnvironmentModel(
            path: "/opt/homebrew/bin:/usr/bin",
            ghConfigDir: "/Users/user-a/.config/gh",
            xdgConfigHome: "/Users/user-a/.config"
        )
        let environment = try ProcessEnvironmentBuilder.gh(
            identity: identity,
            shell: shell,
            token: TestValues.secret(TestValues.token)
        )
        #expect(Set(environment.keys).isSubset(of: ProcessEnvironmentBuilder.ghAllowedKeys))
        #expect(Set(environment.keys).isDisjoint(with: ProcessEnvironmentBuilder.forbiddenKeys))
        #expect(environment[Key.ghToken] == TestValues.token)
        #expect(environment[Key.ghHost] == "github.com")
        #expect(environment[Key.ghPromptDisabled] == "1")
        #expect(environment[Key.ghNoUpdateNotifier] == "1")
        #expect(environment[Key.ghNoExtensionUpdateNotifier] == "1")
        #expect(environment[Key.ghPager] == "cat")
        #expect(environment[Key.pager] == "cat")
        #expect(environment[Key.noColor] == "1")
        #expect(environment[Key.cliColor] == "0")
        #expect(environment[Key.ghSpinnerDisabled] == "1")
        #expect(environment[Key.ghTelemetry] == "false")
        #expect(environment[Key.doNotTrack] == "1")
        #expect(environment[Key.lang] == "en_US.UTF-8")
        #expect(environment[Key.path] == "/opt/homebrew/bin:/usr/bin")
        #expect(environment[Key.ghConfigDir] == "/Users/user-a/.config/gh")
        #expect(environment[Key.xdgConfigHome] == "/Users/user-a/.config")
        #expect(environment[Key.xdgCacheHome] == nil, "only captured XDG keys are passed")
        #expect(environment[Key.sshAuthSock] == nil)
        #expect(environment[Key.logname] == environment[Key.user])
    }

    @Test func ghEnvironmentWithoutTokenHasNoGHToken() throws {
        let environment = try ProcessEnvironmentBuilder.gh(identity: TestValues.identity, shell: .empty, token: nil)
        #expect(environment[Key.ghToken] == nil)
        #expect(environment[Key.path] == GHConstants.defaultPATH)
    }

    @Test(arguments: ["", "gho_abc\nGH_DEBUG=1", "token with space", "tok\u{0}en"])
    func malformedTokensAreRejected(token: String) {
        #expect(throws: GHError.tokenRevoked) {
            try ProcessEnvironmentBuilder.gh(identity: TestValues.identity, shell: .empty, token: TestValues.secret(token))
        }
    }

    @Test func gitEnvironment() {
        let identity = ProcessIdentityModel.current(processEnvironment: Self.hostileProcessEnvironment)
        let environment = ProcessEnvironmentBuilder.git(identity: identity, shell: TestValues.shell)
        #expect(Set(environment.keys).isSubset(of: ProcessEnvironmentBuilder.gitAllowedKeys))
        #expect(Set(environment.keys).isDisjoint(with: ProcessEnvironmentBuilder.forbiddenKeys))
        #expect(environment[Key.gitTerminalPrompt] == "0")
        #expect(environment[Key.gitConfigNoSystem] == "1")
        #expect(environment[Key.gitSSHCommand] == "/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=15")
        #expect(environment[Key.sshAuthSock] == "/private/tmp/launchd.sock", "falls back to the app's own agent socket")
        #expect(environment[Key.ghToken] == nil)
    }

    @Test func sshEnvironmentPrefersTheShellAgentSocket() {
        let shell = ShellEnvironmentModel(sshAuthSock: "/Users/user-a/.1password/agent.sock")
        let environment = ProcessEnvironmentBuilder.ssh(identity: TestValues.identity, shell: shell)
        #expect(Set(environment.keys).isSubset(of: ProcessEnvironmentBuilder.sshAllowedKeys))
        #expect(environment[Key.sshAuthSock] == "/Users/user-a/.1password/agent.sock")
    }

    @Test func shellProbeEnvironmentCarriesOnlyIdentityAndMarker() {
        let environment = ProcessEnvironmentBuilder.shellProbe(identity: TestValues.identity)
        #expect(Set(environment.keys) == [
            Key.home, Key.user, Key.logname, Key.tmpdir, Key.path, Key.lang, Key.term, Key.resolvingEnvironment,
        ])
        #expect(environment[Key.resolvingEnvironment] == "1")
        #expect(environment[Key.path] == GHConstants.systemPATH)
    }
}

@Suite("ShellEnvironmentResolver")
struct ShellEnvironmentResolverTests {
    @Test func extractsOnlyAllowlistedKeysBetweenMarkers() throws {
        let output = try Fixture.string("shell/probe-noisy.txt")
        let model = try #require(ShellEnvironmentResolver.parse(output))
        #expect(model.path == "/opt/homebrew/bin:/usr/bin:/bin", "relative PATH entries are dropped")
        #expect(model.ghConfigDir == nil, "empty values are absent")
        #expect(model.xdgConfigHome == "/Users/user-a/.config")
        #expect(model.xdgCacheHome == nil, "relative directories are dropped")
        #expect(model.sshAuthSock == "/private/tmp/com.apple.launchd.fixture/Listeners")
        let mirror = String(describing: model)
        #expect(!mirror.contains("should-never-be-captured"))
        #expect(!mirror.contains("/evil"))
    }

    @Test func missingMarkersYieldNil() {
        #expect(ShellEnvironmentResolver.parse("PATH=/usr/bin\0") == nil)
        #expect(ShellEnvironmentResolver.parse("__FXV_B__PATH=/usr/bin\0") == nil)
    }

    @Test func scriptRequestsOnlyAllowlistedKeysWithAbsoluteCommands() {
        let script = ShellEnvironmentResolver.script
        for key in ShellEnvironmentResolver.capturedKeys {
            #expect(script.contains("/usr/bin/printenv \(key)"))
        }
        #expect(!script.contains("env -0"))
        let commands = script.components(separatedBy: "; ")
        #expect(commands.allSatisfy { $0.hasPrefix("/usr/bin/") })
    }

    @Test func flavorFlags() {
        typealias Flavor = ShellEnvironmentResolver.ShellFlavor
        #expect(Flavor(shellPath: "/bin/zsh") == .posix)
        #expect(Flavor(shellPath: "/opt/homebrew/bin/fish") == .fish)
        #expect(Flavor(shellPath: "/bin/tcsh") == .csh)
        #expect(Flavor.posix.arguments(script: "s", interactive: false) == ["-l", "-c", "s"])
        #expect(Flavor.posix.arguments(script: "s", interactive: true) == ["-i", "-l", "-c", "s"])
        #expect(Flavor.fish.arguments(script: "s", interactive: true) == ["-i", "-l", "-c", "s"])
        #expect(Flavor.csh.arguments(script: "s", interactive: false) == ["-c", "s"])
    }

    @Test func fallsBackToInteractiveLoginWhenTheFirstProbeHasNoMarkers() async throws {
        let runner = FakeCommandRunner()
        runner.enqueue(.success("zsh: no markers here"), matching: Match.prefix(["-l"]))
        runner.enqueue(.success("noise__FXV_B__PATH=/usr/local/bin\n\0__FXV_E__"), matching: Match.prefix(["-i", "-l"]))
        let resolver = ShellEnvironmentResolver(
            runner: runner,
            identity: TestValues.identity,
            workingDirectory: TestValues.workingDirectory,
            shellPath: "/bin/zsh"
        )
        let model = try await resolver.resolve()
        #expect(model.path == "/usr/local/bin")
        let calls = runner.invocations
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.executablePath == "/bin/zsh" })
        #expect(calls.allSatisfy { $0.timeout == Timeouts.shellProbe })
        #expect(calls.allSatisfy { $0.environment[ProcessEnvironmentBuilder.Key.resolvingEnvironment] == "1" })
        #expect(calls.allSatisfy { $0.stdin.isEmpty })
    }

    @Test func returnsEmptyWhenBothProbesFail() async throws {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: [], with: .failure(stderr: "boom"))
        let resolver = ShellEnvironmentResolver(
            runner: runner,
            identity: TestValues.identity,
            workingDirectory: TestValues.workingDirectory,
            shellPath: "/bin/zsh"
        )
        #expect(try await resolver.resolve() == .empty)
    }

    @Test func realPOSIXShellProbe() async throws {
        let directory = try TemporaryDirectory()
        let resolver = ShellEnvironmentResolver(
            runner: ProcessRunner(),
            identity: ProcessIdentityModel(
                home: directory.url.path,
                user: "user-a",
                temporaryDirectory: directory.url.path
            ),
            workingDirectory: directory.url,
            shellPath: "/bin/sh"
        )
        let model = try await resolver.resolve()
        let path = try #require(model.path)
        #expect(path.split(separator: ":").allSatisfy { $0.hasPrefix("/") })
    }
}

@Suite("GHVersion")
struct GHVersionTests {
    @Test func parsesGHVersionOutput() throws {
        let version = try #require(GHVersion(ghVersionOutput: try Fixture.string("gh/version.txt")))
        #expect(version == GHVersion(major: 2, minor: 102, patch: 0))
        #expect(version.isSupported)
        #expect(version.description == "2.102.0")
    }

    @Test(arguments: [
        ("2.96.9", false), ("2.97.0", true), ("2.97.1", true), ("3.0.0", true), ("1.99.99", false), ("2.90.0", false),
    ])
    func floor(text: String, supported: Bool) throws {
        let version = try #require(GHVersion(string: text))
        #expect(version.isSupported == supported)
    }

    @Test func minimumIsTheLimitsFloor() {
        #expect(GHVersion.minimum == GHVersion(major: 2, minor: 97, patch: 0))
        #expect(GHVersion.minimum.description == Limits.minimumGHVersion)
    }

    @Test(arguments: ["", "2.97", "two.97.0", "2..0", "-2.97.0"])
    func rejectsMalformedVersions(text: String) {
        #expect(GHVersion(string: text) == nil)
        #expect(GHVersion(ghVersionOutput: "gh version \(text)") == nil)
    }

    @Test func acceptsPrefixesAndSuffixes() {
        #expect(GHVersion(string: "v2.97.0") == GHVersion(major: 2, minor: 97, patch: 0))
        #expect(GHVersion(string: "2.98.0-pre.1") == GHVersion(major: 2, minor: 98, patch: 0))
        #expect(GHVersion(ghVersionOutput: "gh version 2.97.0\n") == GHVersion(major: 2, minor: 97, patch: 0))
    }

    @Test func ordering() {
        #expect(GHVersion(major: 2, minor: 9, patch: 0) < GHVersion(major: 2, minor: 10, patch: 0))
        #expect(GHVersion(major: 2, minor: 97, patch: 0) < GHVersion(major: 2, minor: 97, patch: 1))
    }
}

@Suite("GHLocator")
struct GHLocatorTests {
    private func locator(_ runner: FakeCommandRunner, home: String = "/Users/user-a") -> GHLocator {
        GHLocator(
            runner: runner,
            identity: ProcessIdentityModel(home: home, user: "user-a", temporaryDirectory: "/tmp"),
            workingDirectory: TestValues.workingDirectory
        )
    }

    @Test func trustsAnOwnedNonWritableExecutable() throws {
        let directory = try TemporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.url.path)
        let gh = try directory.file("gh", contents: "#!/bin/sh\n", mode: 0o755)
        #expect(GHLocator.trust(of: gh.path) == .success(gh.path))
    }

    @Test func rejectsAWorldWritableFile() throws {
        let directory = try TemporaryDirectory()
        let gh = try directory.file("gh", mode: 0o777)
        #expect(GHLocator.trust(of: gh.path) == .failure(.writableFile))
    }

    @Test func rejectsAGroupWritableFile() throws {
        let directory = try TemporaryDirectory()
        let gh = try directory.file("gh", mode: 0o775)
        #expect(GHLocator.trust(of: gh.path) == .failure(.writableFile))
    }

    @Test func acceptsGroupWriteByAdminLikeHomebrew() throws {
        let directory = try TemporaryDirectory()
        let gh = try directory.file("gh", mode: 0o755)
        guard let admin = getgrnam("admin")?.pointee.gr_gid,
              chown(directory.url.path, getuid(), admin) == 0
        else { return } // The test user is not in `admin`; nothing to check.
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: directory.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.url.path) }
        #expect(GHLocator.trust(of: gh.path) == .success(gh.path))
    }

    @Test func realHomebrewGHIsTrustedWhenInstalled() {
        let path = "/opt/homebrew/bin/gh"
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard case .success = GHLocator.trust(of: path) else {
            Issue.record("Homebrew's gh should pass the trust check")
            return
        }
    }

    @Test func rejectsAWorldWritableDirectory() throws {
        let directory = try TemporaryDirectory()
        let gh = try directory.file("gh", mode: 0o755)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.url.path) }
        #expect(GHLocator.trust(of: gh.path) == .failure(.writableDirectory))
    }

    @Test func rejectsASymlinkInAWritableDirectory() throws {
        let trusted = try TemporaryDirectory()
        let gh = try trusted.file("gh", mode: 0o755)
        let writable = try TemporaryDirectory()
        let link = writable.url.appendingPathComponent("gh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: gh)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: writable.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: writable.url.path) }
        #expect(GHLocator.trust(of: link.path) == .failure(.writableDirectory))
    }

    @Test func resolvesSymlinks() throws {
        let directory = try TemporaryDirectory()
        let gh = try directory.file("gh-real", mode: 0o755)
        let link = directory.url.appendingPathComponent("gh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: gh)
        #expect(GHLocator.trust(of: link.path) == .success(gh.path))
    }

    @Test func rejectsNonExecutablesAndMissingFiles() throws {
        let directory = try TemporaryDirectory()
        let gh = try directory.file("gh", mode: 0o644)
        #expect(GHLocator.trust(of: gh.path) == .failure(.notExecutable))
        #expect(GHLocator.trust(of: directory.url.appendingPathComponent("absent").path) == .failure(.notFound))
        #expect(GHLocator.trust(of: directory.url.path) == .failure(.notRegularFile))
    }

    @Test func candidateOrder() {
        let paths = GHLocator.candidatePaths(shellPATH: "/custom/bin:relative:/opt/homebrew/bin", home: "/Users/user-a")
        #expect(paths == [
            "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/custom/bin/gh", "/opt/local/bin/gh",
            "/Users/user-a/.nix-profile/bin/gh", "/run/current-system/sw/bin/gh",
            "/nix/var/nix/profiles/default/bin/gh", "/Users/user-a/.local/bin/gh",
        ])
    }

    @Test func overrideToANonexistentPathIsNotInstalled() async {
        let runner = FakeCommandRunner()
        await #expect(throws: GHError.notInstalled) {
            try await locator(runner).locate(overridePath: "/nonexistent/gh", shell: .empty)
        }
        #expect(runner.invocations.isEmpty)
    }

    @Test func overrideToAnUntrustedBinaryIsRejectedBeforeRunning() async throws {
        let directory = try TemporaryDirectory()
        let gh = try directory.file("gh", mode: 0o777)
        let runner = FakeCommandRunner()
        await #expect(throws: GHError.untrustedBinary(path: gh.path)) {
            try await locator(runner).locate(overridePath: gh.path, shell: .empty)
        }
        #expect(runner.invocations.isEmpty)
    }

    @Test func overrideReportsVersionAndPaths() async throws {
        let directory = try TemporaryDirectory()
        let gh = try directory.file("gh", mode: 0o755)
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: ["--version"], with: .success(try Fixture.string("gh/version.txt")))
        let installation = try await locator(runner).locate(overridePath: gh.path, shell: .empty)
        #expect(installation.version == GHVersion(major: 2, minor: 102, patch: 0))
        #expect(installation.resolvedPath == gh.path)
        #expect(installation.hasChanged(fromResolvedPath: "/opt/homebrew/bin/gh"))
        #expect(!installation.hasChanged(fromResolvedPath: gh.path))
        let call = try #require(runner.invocations.first)
        #expect(call.arguments == ["--version"])
        #expect(call.environment[ProcessEnvironmentBuilder.Key.ghToken] == nil)
    }

    @Test func oldVersionIsRejected() async throws {
        let directory = try TemporaryDirectory()
        let gh = try directory.file("gh", mode: 0o755)
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: ["--version"], with: .success(try Fixture.string("gh/version-old.txt")))
        await #expect(throws: GHError.versionTooOld(
            found: GHVersion(major: 2, minor: 90, patch: 0),
            required: GHVersion(major: 2, minor: 97, patch: 0)
        )) {
            try await locator(runner).locate(overridePath: gh.path, shell: .empty)
        }
    }

    @Test func searchSkipsMissingCandidatesAndUsesTheShellPATH() async throws {
        let directory = try TemporaryDirectory()
        let gh = try directory.file("gh", mode: 0o755)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.url.path)
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: ["--version"], with: .success("gh version 2.97.0 (2026-07-01)\n"))
        let home = try TemporaryDirectory()
        // Homebrew paths may exist on the test machine; a trusted one there is also acceptable.
        let installation = try await locator(runner, home: home.url.path)
            .locate(overridePath: nil, shell: ShellEnvironmentModel(path: directory.url.path))
        #expect(installation.version.isSupported)
        let expected = GHLocator.candidatePaths(shellPATH: directory.url.path, home: home.url.path)
            .first { FileManager.default.fileExists(atPath: $0) }
        #expect(installation.path == expected ?? gh.path)
    }
}
