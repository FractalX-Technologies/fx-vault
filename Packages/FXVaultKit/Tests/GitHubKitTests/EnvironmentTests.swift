import Foundation
import os
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
    typealias Resolver = ShellEnvironmentResolver

    /// What an interactive shell prints when `~/.zshrc` (or `~/.bashrc`, fish's interactive
    /// block) adds `~/.local/bin` to PATH, sets `GH_CONFIG_DIR` and exports `GH_TOKEN`.
    static let rcOutput = [
        "Last login: noise__FXV_B__PATH=/Users/user-a/.local/bin:/opt/homebrew/bin:/usr/bin:/bin\n",
        "GH_CONFIG_DIR=/Users/user-a/.config/gh-work\n",
        "XDG_CONFIG_HOME=",
        "FXV_GH=/Users/user-a/.local/bin/gh\n",
        "FXV_SET=GH_TOKEN",
        "FXV_SET=GH_CONFIG_DIR",
        "__FXV_E__",
    ].joined(separator: "\0")

    /// What the same user's login shell prints: only the profile files ran.
    static let profileOutput = [
        "__FXV_B__PATH=/opt/homebrew/bin:/usr/bin:/bin\n",
        "GH_CONFIG_DIR=",
        "FXV_GH=/opt/homebrew/bin/gh\n",
        "__FXV_E__",
    ].joined(separator: "\0")

    private func resolver(_ runner: any CommandRunning, shellPath: String) -> Resolver {
        Resolver(runner: runner, identity: TestValues.identity, workingDirectory: TestValues.workingDirectory, shellPath: shellPath)
    }

    @Test func extractsOnlyAllowlistedKeysBetweenMarkers() throws {
        let output = try Fixture.string("shell/probe-noisy.txt")
        let model = try #require(Resolver.parse(output))
        #expect(model.path == "/opt/homebrew/bin:/usr/bin:/bin", "relative PATH entries are dropped")
        #expect(model.ghConfigDir == nil, "empty values are absent")
        #expect(model.xdgConfigHome == "/Users/user-a/.config")
        #expect(model.xdgCacheHome == nil, "relative directories are dropped")
        #expect(model.sshAuthSock == "/private/tmp/com.apple.launchd.fixture/Listeners")
        #expect(model.ghPath == nil)
        #expect(model.setVariables.isEmpty)
        let mirror = String(describing: model)
        #expect(!mirror.contains("should-never-be-captured"))
        #expect(!mirror.contains("/evil"))
    }

    @Test func missingMarkersYieldNil() {
        #expect(Resolver.parse("PATH=/usr/bin\0") == nil)
        #expect(Resolver.parse("__FXV_B__PATH=/usr/bin\0") == nil)
    }

    @Test func scriptRequestsOnlyAllowlistedKeysWithAbsoluteCommands() {
        let script = Resolver.script
        for key in Resolver.capturedKeys {
            #expect(script.contains("/usr/bin/printenv \(key)"))
        }
        #expect(!script.contains("env -0"))
        let report = "/bin/sh -c '\(Resolver.reportScript)'"
        #expect(script.contains(report))
        let topLevel = script.replacingOccurrences(of: report, with: "/bin/sh -c REPORT").components(separatedBy: "; ")
        #expect(topLevel.allSatisfy { $0.hasPrefix("/usr/bin/") || $0 == "/bin/sh -c REPORT" })
    }

    /// The report runs single-quoted in every shell (sh, zsh, bash, fish, csh): no `'`, no `!`
    /// (csh history) and no newline. It names variables and never prints one.
    @Test func reportScriptNamesVariablesWithoutPrintingThem() {
        let report = Resolver.reportScript
        #expect(!report.contains("'"))
        #expect(!report.contains("!"))
        #expect(!report.contains("\n"))
        #expect(report.contains("command -v gh"))
        #expect(!report.contains("printenv"))
        for name in ShellVariableName.allCases {
            #expect(report.contains("[ -n \"${\(name.rawValue)-}\" ] && /usr/bin/printf \"%s\\0\" FXV_SET=\(name.rawValue)"))
        }
        #expect(report.components(separatedBy: "${").count - 1 == ShellVariableName.allCases.count, "values are only tested")
        for name in ShellVariableName.tokenVariables {
            #expect(!Resolver.script.contains("printenv \(name.rawValue)"))
        }
    }

    @Test func parsesTheGHPathAndTheVariableFlags() throws {
        let output = "__FXV_B__PATH=/opt/homebrew/bin:/usr/bin\n\0GH_CONFIG_DIR=\0FXV_GH=/opt/homebrew/bin/gh\n\0"
            + "FXV_SET=GH_TOKEN\0FXV_SET=GH_HOST\0FXV_SET=NOT_A_FLAG\0FXV_GH=/usr/local/bin/gh\0__FXV_E__"
        let model = try #require(Resolver.parse(output))
        #expect(model.ghPath == "/opt/homebrew/bin/gh", "the first answer wins")
        #expect(model.setVariables == [.ghToken, .ghHost])
        #expect(model.exportedTokenVariables == [.ghToken])
        #expect(model.path == "/opt/homebrew/bin:/usr/bin")
    }

    @Test(arguments: [
        "", "gh", "bin/gh", "/opt/homebrew/bin/hub", "alias gh='/usr/local/bin/gh'", "/opt/home\u{202E}brew/bin/gh",
        "gh: aliased to /usr/local/bin/gh", "/opt/homebrew/bin/gh\u{7}",
    ])
    func rejectsGHAnswersThatAreNotAnAbsolutePathToGH(answer: String) throws {
        let model = try #require(Resolver.parse("__FXV_B__FXV_GH=\(answer)\n\0__FXV_E__"))
        #expect(model.ghPath == nil)
    }

    /// A probe that printed token values (the real script never does) still yields a model
    /// without them: only allowlisted keys, an absolute `…/gh` path and exact variable names are
    /// kept, and the model stores enum cases, not text from the output.
    @Test func tokenValuesInTheOutputNeverReachTheModel() throws {
        let token = TestValues.token
        let output = [
            "noise \(token) __FXV_B__GH_TOKEN=\(token)\n", "GITHUB_TOKEN=\(token)", "FXV_SET=\(token)",
            "FXV_SET=GH_TOKEN=\(token)", "FXV_SET=GH_TOKEN \(token)", "FXV_GH=\(token)", "FXV_GH=/\(token)",
            "XDG_CONFIG_HOME=\(token)", "\(token)=GH_TOKEN", "PATH=\(token)", "FXV_SET=GITHUB_TOKEN",
            "__FXV_E__ \(token)",
        ].joined(separator: "\0")
        let model = try #require(Resolver.parse(output))
        #expect(model.setVariables == [.githubToken])
        #expect(model.ghPath == nil)
        #expect(model.xdgConfigHome == nil)
        #expect(model.path == nil)
        for text in [String(describing: model), String(reflecting: model)] {
            #expect(!text.contains(token))
        }
    }

    @Test func flavorFlags() {
        typealias Flavor = Resolver.ShellFlavor
        #expect(Flavor(shellPath: "/bin/zsh") == .posix)
        #expect(Flavor(shellPath: "/opt/homebrew/bin/fish") == .fish)
        #expect(Flavor(shellPath: "/bin/tcsh") == .csh)
        #expect(Flavor.posix.arguments(script: "s", interactive: false) == ["-l", "-c", "s"])
        #expect(Flavor.posix.arguments(script: "s", interactive: true) == ["-i", "-l", "-c", "s"])
        #expect(Flavor.fish.arguments(script: "s", interactive: true) == ["-i", "-l", "-c", "s"])
        #expect(Flavor.csh.arguments(script: "s", interactive: false) == ["-c", "s"])
        #expect(Flavor.csh.arguments(script: "s", interactive: true) == ["-i", "-c", "s"])
        #expect(Resolver.attemptOrder == [.interactive, .login])
    }

    /// Interactive first (v0.3.1): settings only `~/.zshrc` (or `~/.bashrc`, fish's interactive
    /// block) makes are seen exactly as in Terminal, with one shell start.
    @Test(arguments: [
        ("/bin/zsh", ["-i", "-l", "-c"]), ("/bin/bash", ["-i", "-l", "-c"]),
        ("/opt/homebrew/bin/fish", ["-i", "-l", "-c"]), ("/bin/tcsh", ["-i", "-c"]),
    ])
    func interactiveShellRunsFirstAndSeesRCOnlySettings(shellPath: String, flags: [String]) async throws {
        let runner = FakeCommandRunner()
        runner.enqueue(.success(Self.rcOutput), matching: Match.prefix(flags))
        let model = try await resolver(runner, shellPath: shellPath).resolve()
        #expect(model.probeMode == .interactive)
        #expect(model.shellPath == shellPath)
        #expect(model.ghConfigDir == "/Users/user-a/.config/gh-work")
        #expect(model.ghPath == "/Users/user-a/.local/bin/gh")
        #expect(model.path == "/Users/user-a/.local/bin:/opt/homebrew/bin:/usr/bin:/bin")
        #expect(model.setVariables == [.ghToken, .ghConfigDir])
        #expect(model.exportedTokenVariables == [.ghToken])
        let calls = runner.invocations
        #expect(calls.count == 1)
        #expect(calls.first.map { Array($0.arguments.dropLast()) } == flags)
        #expect(calls.first?.arguments.last == Resolver.script)
    }

    /// The fallback reads only the profile files, so what `~/.zshrc` sets is missing there:
    /// the reason the interactive shell runs first.
    @Test(arguments: [
        ("/bin/zsh", ["-i", "-l", "-c"], ["-l", "-c"]), ("/bin/bash", ["-i", "-l", "-c"], ["-l", "-c"]),
        ("/opt/homebrew/bin/fish", ["-i", "-l", "-c"], ["-l", "-c"]), ("/bin/tcsh", ["-i", "-c"], ["-c"]),
    ])
    func fallsBackToTheLoginShellWhenTheInteractiveShellPrintsNoMarkers(
        shellPath: String,
        interactive: [String],
        login: [String]
    ) async throws {
        let runner = FakeCommandRunner()
        runner.enqueue(.success("zsh: no markers here"), matching: Match.prefix(interactive))
        runner.enqueue(.success(Self.profileOutput), matching: Match.prefix(login))
        let model = try await resolver(runner, shellPath: shellPath).resolve()
        #expect(model.probeMode == .login)
        #expect(model.ghConfigDir == nil, "rc-only settings are not seen by the login shell")
        #expect(model.ghPath == "/opt/homebrew/bin/gh")
        #expect(model.setVariables.isEmpty)
        let calls = runner.invocations
        #expect(calls.map { Array($0.arguments.dropLast()) } == [interactive, login])
        #expect(calls.allSatisfy { $0.executablePath == shellPath })
        #expect(calls.allSatisfy { $0.timeout == Timeouts.shellProbe })
        #expect(calls.allSatisfy { $0.environment[ProcessEnvironmentBuilder.Key.resolvingEnvironment] == "1" })
        #expect(calls.allSatisfy { $0.stdin.isEmpty })
    }

    @Test func fallsBackToTheLoginShellWhenTheInteractiveShellTimesOut() async throws {
        let runner = FakeCommandRunner()
        var timedOut = FakeCommandRunner.Response.success(Self.rcOutput)
        timedOut.didTimeOut = true
        runner.enqueue(timedOut, matching: Match.prefix(["-i", "-l", "-c"]))
        runner.enqueue(.success(Self.profileOutput), matching: Match.prefix(["-l", "-c"]))
        let model = try await resolver(runner, shellPath: "/bin/zsh").resolve()
        #expect(model.probeMode == .login)
        #expect(model.ghConfigDir == nil, "a timed-out attempt's output is discarded")
        #expect(runner.invocations.count == 2)
    }

    @Test func reportsFailureWhenBothAttemptsFail() async throws {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: [], with: .failure(stderr: "boom"))
        let model = try await resolver(runner, shellPath: "/bin/zsh").resolve()
        #expect(model.probeMode == .failed)
        #expect(model.shellPath == "/bin/zsh")
        #expect(model.path == nil)
        #expect(model.ghPath == nil)
        #expect(model.setVariables.isEmpty)
        #expect(runner.invocations.count == 2)
    }

    @Test func realPOSIXShellProbe() async throws {
        let directory = try TemporaryDirectory()
        let resolver = Resolver(
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
        #expect(model.probeMode == .interactive)
        let path = try #require(model.path)
        #expect(path.split(separator: ":").allSatisfy { $0.hasPrefix("/") })
        #expect(model.setVariables.isEmpty)
    }
}

/// Records a copy of every stdout so a test can prove what never reached it.
private final class StdoutRecordingRunner: CommandRunning, Sendable {
    private let base = ProcessRunner()
    private let outputs = OSAllocatedUnfairLock<[Data]>(initialState: [])

    var recorded: [Data] {
        outputs.withLock { $0 }
    }

    func run(_ spec: CommandSpec) async throws(CommandRunnerError) -> CommandResult {
        let result = try await base.run(spec)
        let copy = result.stdout.withUnsafeBytes { Data($0) }
        outputs.withLock { $0.append(copy) }
        return result
    }
}

/// The probe in the real shells of this Mac with a throwaway home (v0.3.1): what only the
/// interactive start-up file sets is captured, the gh it puts first on PATH is found, the token
/// variable is flagged by name, and the probe's raw output never contains the token value.
@Suite("Shell probe in real shells", .serialized)
struct RealShellProbeTests {
    struct ShellCase: Sendable, CustomTestStringConvertible {
        let shellPath: String
        /// Start-up files relative to the home; `@TOKEN@` is replaced by the synthetic token.
        let files: [String: String]
        let expectedFlags: Set<ShellVariableName>
        let expectsConfigDir: Bool
        var testDescription: String { shellPath }
    }

    static let fishPaths = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
    static let tokenPlaceholder = "@TOKEN@"

    static let cases: [ShellCase] = [
        ShellCase(
            shellPath: "/bin/zsh",
            files: [".zshrc": "export PATH=\"$HOME/rcbin:$PATH\"\nexport GH_CONFIG_DIR=\"$HOME/ghconfig\"\nexport GH_TOKEN=\"@TOKEN@\"\n"],
            expectedFlags: [.ghToken, .ghConfigDir],
            expectsConfigDir: true
        ),
        ShellCase(
            shellPath: "/bin/bash",
            files: [
                ".bash_profile": "[ -f \"$HOME/.bashrc\" ] && . \"$HOME/.bashrc\"\n",
                ".bashrc": "case $- in *i*) ;; *) return;; esac\nexport PATH=\"$HOME/rcbin:$PATH\"\n"
                    + "export GH_CONFIG_DIR=\"$HOME/ghconfig\"\nexport GITHUB_TOKEN=\"@TOKEN@\"\n",
            ],
            expectedFlags: [.githubToken, .ghConfigDir],
            expectsConfigDir: true
        ),
        ShellCase(
            shellPath: "/bin/sh",
            files: [".profile": "export PATH=\"$HOME/rcbin:$PATH\"\nexport GH_TOKEN=\"@TOKEN@\"\nexport GH_HOST=\"example.invalid\"\n"],
            expectedFlags: [.ghToken, .ghHost],
            expectsConfigDir: false
        ),
        ShellCase(
            shellPath: "/bin/tcsh",
            files: [".tcshrc": "setenv PATH \"${HOME}/rcbin:${PATH}\"\nsetenv GH_CONFIG_DIR \"${HOME}/ghconfig\"\nsetenv GH_TOKEN \"@TOKEN@\"\n"],
            expectedFlags: [.ghToken, .ghConfigDir],
            expectsConfigDir: true
        ),
    ] + fishPaths.filter { FileManager.default.isExecutableFile(atPath: $0) }.prefix(1).map { fish in
        ShellCase(
            shellPath: fish,
            files: [".config/fish/config.fish": "if status is-interactive\n  set -gx GH_CONFIG_DIR $HOME/ghconfig\nend\n"
                + "set -gx PATH $HOME/rcbin $PATH\nset -gx GH_TOKEN @TOKEN@\n"],
            expectedFlags: [.ghToken, .ghConfigDir],
            expectsConfigDir: true
        )
    }

    @Test(arguments: cases)
    func capturesStartupSettingsWithoutLeakingTheToken(_ shellCase: ShellCase) async throws {
        guard FileManager.default.isExecutableFile(atPath: shellCase.shellPath) else { return }
        let home = try TemporaryDirectory()
        let token = TestValues.token
        let bin = home.url.appendingPathComponent("rcbin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let gh = bin.appendingPathComponent("gh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: gh)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        for (name, contents) in shellCase.files {
            let file = home.url.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.replacingOccurrences(of: Self.tokenPlaceholder, with: token).utf8).write(to: file)
        }
        let runner = StdoutRecordingRunner()
        let resolver = ShellEnvironmentResolver(
            runner: runner,
            identity: ProcessIdentityModel(home: home.url.path, user: "user-a", temporaryDirectory: home.url.path),
            workingDirectory: home.url,
            shellPath: shellCase.shellPath
        )
        let model = try await resolver.resolve()

        #expect(model.probeMode == .interactive)
        #expect(model.ghPath == gh.path)
        #expect(model.path?.hasPrefix(bin.path + ":") == true)
        #expect(model.setVariables == shellCase.expectedFlags)
        #expect(model.ghConfigDir == (shellCase.expectsConfigDir ? home.url.appendingPathComponent("ghconfig").path : nil))
        #expect(!runner.recorded.isEmpty)
        for output in runner.recorded {
            #expect(output.range(of: Data(token.utf8)) == nil, "the token value never reaches the probe's stdout")
        }
        #expect(!String(reflecting: model).contains(token))
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
        // Homebrew paths may exist on the test machine: the first existing candidate decides.
        let expected = GHLocator.candidatePaths(shellPATH: directory.url.path, home: home.url.path)
            .first { FileManager.default.fileExists(atPath: $0) } ?? gh.path
        let report = await locator(runner, home: home.url.path)
            .inspect(overridePath: nil, shell: ShellEnvironmentModel(path: directory.url.path))
        #expect(report.decisive?.path == expected)
        if case .success = GHLocator.trust(of: expected) {
            #expect(report.installation?.path == expected)
            #expect(report.installation?.version.isSupported == true)
        } else {
            #expect(report.outcome == .failure(.untrustedBinary(path: expected)))
        }
    }
}

/// Which gh wins (v0.3.1), over a fake file system so other owners can be modeled: the shell's
/// gh first, the first existing candidate decides, consented trust for one foreign owner.
@Suite("GHLocator decisions")
struct GHLocatorDecisionTests {
    static let me = FakeGHFileInspector.defaultUserID
    static let otherAdmin: uid_t = 502
    static let thirdUser: uid_t = 503
    static let root: uid_t = 0
    static let homebrewGH = "/opt/homebrew/bin/gh"
    static let homebrewResolved = "/opt/homebrew/Cellar/gh/2.102.0/bin/gh"
    static let pkgGH = "/usr/local/bin/gh"

    /// `/opt/homebrew` owned by `homebrewOwner`, and GitHub's `.pkg` gh in `/usr/local/bin`.
    static func machine(homebrewOwner: uid_t) -> FakeGHFileInspector {
        let files = FakeGHFileInspector()
        files.setUserName("admin-b", for: otherAdmin)
        files.setUserName("user-c", for: thirdUser)
        files.addHomebrewGH(owner: homebrewOwner)
        files.addFolder("/usr/local/bin", owner: root, group: FakeGHFileInspector.wheelGroupID)
        files.addFile(pkgGH, owner: root, group: FakeGHFileInspector.wheelGroupID)
        return files
    }

    static func runner(homebrew: String = "2.102.0", pkg: String = "2.90.0") -> FakeCommandRunner {
        let runner = FakeCommandRunner()
        runner.stub(executablePath: homebrewResolved, argumentsPrefix: ["--version"], with: .success("gh version \(homebrew) (2026-09-30)\n"))
        runner.stub(executablePath: pkgGH, argumentsPrefix: ["--version"], with: .success("gh version \(pkg) (2026-05-01)\n"))
        return runner
    }

    static func locator(_ runner: FakeCommandRunner, _ files: FakeGHFileInspector) -> GHLocator {
        GHLocator(
            runner: runner,
            identity: ProcessIdentityModel(home: "/Users/user-a", user: "user-a", temporaryDirectory: "/tmp"),
            workingDirectory: TestValues.workingDirectory,
            fileInspector: files
        )
    }

    /// The shell probe of a user whose Terminal runs Homebrew's gh.
    static let homebrewShell = ShellEnvironmentModel(
        path: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        ghPath: homebrewGH,
        probeMode: .interactive
    )

    @Test func theShellGHIsTheFirstCandidateAfterTheOverride() {
        let shell = ShellEnvironmentModel(path: "/custom/bin:relative:/opt/homebrew/bin", ghPath: "/Users/user-a/.local/bin/gh")
        let candidates = GHLocator.candidates(overridePath: nil, shell: shell, home: "/Users/user-a")
        #expect(candidates.map(\.path) == [
            "/Users/user-a/.local/bin/gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/custom/bin/gh",
            "/opt/local/bin/gh", "/Users/user-a/.nix-profile/bin/gh", "/run/current-system/sw/bin/gh",
            "/nix/var/nix/profiles/default/bin/gh",
        ], "the shell's gh is listed once, first")
        #expect(candidates.map(\.source) == [.shell, .homebrew, .homebrew, .shellPATH, .fallback, .fallback, .fallback, .fallback])
        let override = GHLocator.candidates(overridePath: "~/bin/gh", shell: shell, home: "/Users/user-a")
        #expect(override.map(\.path) == ["/Users/user-a/bin/gh"])
        #expect(override.map(\.source) == [.override])
    }

    /// Several trusted gh binaries: the shell's is used, never an older one ahead of it, and
    /// the others are only reported.
    @Test func theShellGHWinsOverOtherTrustedCandidates() async throws {
        let files = Self.machine(homebrewOwner: Self.me)
        let runner = Self.runner(homebrew: "2.102.0", pkg: "2.98.0")
        let shell = ShellEnvironmentModel(path: "/usr/local/bin:/opt/homebrew/bin:/usr/bin", ghPath: Self.pkgGH)
        let report = await Self.locator(runner, files).inspect(overridePath: nil, shell: shell, checksEveryVersion: true)
        #expect(report.installation?.path == Self.pkgGH, "Terminal runs /usr/local/bin/gh, so FX Vault does too")
        #expect(report.decisive?.source == .shell)
        #expect(report.candidates.first { $0.path == Self.homebrewGH }?.version == GHVersion(major: 2, minor: 102, patch: 0))

        let homebrewFirst = await Self.locator(Self.runner(homebrew: "2.102.0", pkg: "2.98.0"), files)
            .inspect(overridePath: nil, shell: Self.homebrewShell)
        #expect(homebrewFirst.installation?.version == GHVersion(major: 2, minor: 102, patch: 0))
        #expect(homebrewFirst.installation?.resolvedPath == Self.homebrewResolved)
        #expect(homebrewFirst.candidates.first { $0.path == Self.pkgGH }?.version == nil, "only the decisive gh runs")
    }

    /// Case (c) of the bug report: Homebrew belongs to another administrator. FX Vault used to
    /// skip it and run the older `.pkg` gh ("Update the GitHub CLI") while Terminal ran 2.102.0.
    @Test func aForeignOwnedShellGHBlocksInsteadOfFallingBack() async throws {
        let files = Self.machine(homebrewOwner: Self.otherAdmin)
        let runner = Self.runner()
        let report = await Self.locator(runner, files).inspect(overridePath: nil, shell: Self.homebrewShell)
        #expect(report.outcome == .failure(.untrustedBinary(path: Self.homebrewGH)))
        let decisive = try #require(report.decisive)
        #expect(decisive.path == Self.homebrewGH)
        #expect(decisive.rejection == .untrustedOwner)
        #expect(decisive.foreignOwner == GHBinaryOwnerModel(uid: Self.otherAdmin, name: "admin-b"))
        #expect(decisive.canBeTrusted)
        #expect(decisive.isHomebrew)
        #expect(decisive.trustConsent == GHTrustedBinaryModel(path: Self.homebrewGH, ownerUID: Self.otherAdmin))
        #expect(report.candidates.first { $0.path == Self.pkgGH }?.isAccepted == true)
        #expect(runner.invocations.isEmpty, "nothing runs: the untrusted gh never, the older one not instead")
    }

    @Test func withoutAShellGHTheFirstExistingCandidateStillDecides() async throws {
        let files = Self.machine(homebrewOwner: Self.otherAdmin)
        let report = await Self.locator(Self.runner(), files).inspect(overridePath: nil, shell: ShellEnvironmentModel(probeMode: .failed))
        #expect(report.outcome == .failure(.untrustedBinary(path: Self.homebrewGH)))
        #expect(report.decisive?.source == .homebrew)
    }

    @Test func consentedTrustAcceptsThatExactPathAndOwner() async throws {
        let files = Self.machine(homebrewOwner: Self.otherAdmin)
        let consent = GHTrustedBinaryModel(path: Self.homebrewGH, ownerUID: Self.otherAdmin)
        let report = await Self.locator(Self.runner(), files).inspect(overridePath: nil, shell: Self.homebrewShell, trustedBinary: consent)
        let installation = try #require(report.installation)
        #expect(installation.path == Self.homebrewGH)
        #expect(installation.resolvedPath == Self.homebrewResolved)
        #expect(installation.version == GHVersion(major: 2, minor: 102, patch: 0))
        #expect(report.decisive?.isTrustedByConsent == true)
        #expect(report.decisive?.foreignOwner?.name == "admin-b")

        // Revoked: rejected again.
        let revoked = await Self.locator(Self.runner(), files).inspect(overridePath: nil, shell: Self.homebrewShell, trustedBinary: nil)
        #expect(revoked.outcome == .failure(.untrustedBinary(path: Self.homebrewGH)))

        // The override path is the same check.
        let viaOverride = try await Self.locator(Self.runner(), files).locate(overridePath: Self.homebrewGH, shell: .empty, trustedBinary: consent)
        #expect(viaOverride.path == Self.homebrewGH)
    }

    @Test func consentEndsWhenTheOwnerChanges() async throws {
        let files = Self.machine(homebrewOwner: Self.otherAdmin)
        let consent = GHTrustedBinaryModel(path: Self.homebrewGH, ownerUID: Self.otherAdmin)
        for path in ["/opt/homebrew/bin", "/opt/homebrew/Cellar/gh/2.102.0/bin", Self.homebrewResolved] {
            files.setOwner(path, to: Self.thirdUser)
        }
        let report = await Self.locator(Self.runner(), files).inspect(overridePath: nil, shell: Self.homebrewShell, trustedBinary: consent)
        #expect(report.outcome == .failure(.untrustedBinary(path: Self.homebrewGH)))
        #expect(report.decisive?.foreignOwner == GHBinaryOwnerModel(uid: Self.thirdUser, name: "user-c"), "the new owner is named")
    }

    @Test func consentIsForOnePath() async throws {
        let files = Self.machine(homebrewOwner: Self.otherAdmin)
        let elsewhere = GHTrustedBinaryModel(path: "/usr/local/bin/gh", ownerUID: Self.otherAdmin)
        let report = await Self.locator(Self.runner(), files).inspect(overridePath: nil, shell: Self.homebrewShell, trustedBinary: elsewhere)
        #expect(report.outcome == .failure(.untrustedBinary(path: Self.homebrewGH)))
    }

    /// Writable by others is never trustable, consent or not.
    @Test(arguments: [
        (FakeGHFileInspector.staffGroupID, mode_t(0o775), GHBinaryRejection.writableDirectory),
        (FakeGHFileInspector.adminGroupID, mode_t(0o777), GHBinaryRejection.writableDirectory),
    ])
    func writableFoldersAreNeverTrusted(group: gid_t, mode: mode_t, expected: GHBinaryRejection) async throws {
        let files = Self.machine(homebrewOwner: Self.otherAdmin)
        files.addFolder("/opt/homebrew/bin", owner: Self.otherAdmin, group: group, mode: mode)
        let consent = GHTrustedBinaryModel(path: Self.homebrewGH, ownerUID: Self.otherAdmin)
        let report = await Self.locator(Self.runner(), files).inspect(overridePath: nil, shell: Self.homebrewShell, trustedBinary: consent)
        #expect(report.decisive?.rejection == expected)
        #expect(report.decisive?.canBeTrusted == false)
        #expect(report.decisive?.trustConsent == nil)
    }

    @Test func aGroupWritableFileIsNeverTrusted() async throws {
        let files = Self.machine(homebrewOwner: Self.otherAdmin)
        files.addFile(Self.homebrewResolved, owner: Self.otherAdmin, group: FakeGHFileInspector.staffGroupID, mode: 0o775)
        let consent = GHTrustedBinaryModel(path: Self.homebrewGH, ownerUID: Self.otherAdmin)
        let report = await Self.locator(Self.runner(), files).inspect(overridePath: nil, shell: Self.homebrewShell, trustedBinary: consent)
        #expect(report.decisive?.rejection == .writableFile)
    }

    @Test func severalOtherOwnersCannotBeTrusted() async throws {
        let files = Self.machine(homebrewOwner: Self.otherAdmin)
        files.setOwner("/opt/homebrew/bin", to: Self.thirdUser)
        let report = await Self.locator(Self.runner(), files).inspect(overridePath: nil, shell: Self.homebrewShell)
        #expect(report.decisive?.rejection == .untrustedOwner)
        #expect(report.decisive?.foreignOwner == nil)
        #expect(report.decisive?.canBeTrusted == false)
    }

    @Test func rootOrUserOwnedHomebrewNeedsNoConsent() async throws {
        let files = Self.machine(homebrewOwner: Self.me)
        files.setOwner("/opt/homebrew/bin", to: Self.root)
        let report = await Self.locator(Self.runner(), files).inspect(overridePath: nil, shell: Self.homebrewShell)
        #expect(report.installation?.path == Self.homebrewGH)
        #expect(report.decisive?.isTrustedByConsent == false)
    }

    @Test func aFailedVersionCheckOfTheShellGHIsReportedNotSkipped() async throws {
        let files = Self.machine(homebrewOwner: Self.me)
        let runner = FakeCommandRunner()
        runner.stub(executablePath: Self.homebrewResolved, argumentsPrefix: ["--version"], with: .success("shim: no version selected\n"))
        runner.stub(executablePath: Self.pkgGH, argumentsPrefix: ["--version"], with: .success("gh version 2.99.0\n"))
        let report = await Self.locator(runner, files).inspect(overridePath: nil, shell: Self.homebrewShell)
        #expect(report.outcome == .failure(.malformedOutput))
        #expect(report.decisive?.versionFailure == .malformedOutput)
        #expect(!runner.invocations.contains { $0.executablePath == Self.pkgGH })
    }

    @Test func anOldShellGHIsReportedWithItsPath() async throws {
        let files = Self.machine(homebrewOwner: Self.me)
        let shell = ShellEnvironmentModel(path: "/usr/local/bin:/opt/homebrew/bin", ghPath: Self.pkgGH)
        let report = await Self.locator(Self.runner(pkg: "2.90.0"), files).inspect(overridePath: nil, shell: shell)
        #expect(report.outcome == .failure(.versionTooOld(found: GHVersion(major: 2, minor: 90, patch: 0), required: .minimum)))
        #expect(report.decisive?.path == Self.pkgGH)
        #expect(report.decisive?.version == GHVersion(major: 2, minor: 90, patch: 0))
    }

    @Test func nothingAnywhereIsNotInstalled() async {
        let report = await Self.locator(FakeCommandRunner(), FakeGHFileInspector()).inspect(overridePath: nil, shell: Self.homebrewShell)
        #expect(report.outcome == .failure(.notInstalled))
        #expect(report.decisiveIndex == nil)
        #expect(report.candidates.allSatisfy { $0.rejection == .notFound })
    }
}
