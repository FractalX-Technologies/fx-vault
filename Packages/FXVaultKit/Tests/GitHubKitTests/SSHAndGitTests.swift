import Darwin
import Foundation
import Testing
@testable import GitHubKit
import VaultCore

@Suite("SSHConfigParser")
struct SSHConfigParserTests {
    private func fixtureParser() throws -> SSHConfigParser {
        let directory = try Fixture.url("ssh")
        return SSHConfigParser(sshDirectory: directory, homeDirectory: directory.deletingLastPathComponent())
    }

    @Test func listsConcreteValidAliasesInOrder() throws {
        let parser = try fixtureParser()
        let entries = parser.parse(fileAt: try Fixture.url("ssh/config"))
        #expect(entries.map(\.alias) == ["github.com", "github-work", "gh-alt", "gitlab.example", "quoted-alias", "github-personal"])
    }

    @Test func firstHostNameWinsAcrossMatchAndInclude() throws {
        let entries = try fixtureParser().parse(fileAt: try Fixture.url("ssh/config"))
        let byAlias = Dictionary(uniqueKeysWithValues: entries.map { ($0.alias, $0) })
        #expect(byAlias["github-work"]?.hostName == "github.com", "not the Match block's or the include's value")
        #expect(byAlias["gh-alt"]?.hostName == "github.com", "keyword=value form and uppercase HOST")
        #expect(byAlias["github-personal"]?.hostName == "github.com")
        #expect(byAlias["github.com"]?.user == "git")
        #expect(byAlias["quoted-alias"]?.hostName == "github.com", "quotes are removed")
        #expect(byAlias["gitlab.example"]?.hostName == "gitlab.example.com")
        #expect(byAlias["github-personal"]?.sourcePath.hasSuffix("config.d/work.conf") == true)
        #expect(entries.filter(\.looksLikeGitHub).map(\.alias)
            == ["github.com", "github-work", "gh-alt", "quoted-alias", "github-personal"])
    }

    @Test func wildcardsNegationsAndUnsafeAliasesAreSkipped() throws {
        let aliases = try fixtureParser().parse(fileAt: try Fixture.url("ssh/config")).map(\.alias)
        for rejected in ["*", "*.internal", "!bastion", "-oProxyCommand=evil", "bad;alias"] {
            #expect(!aliases.contains(rejected))
        }
    }

    @Test func includeCyclesTerminate() throws {
        let directory = try TemporaryDirectory()
        _ = try directory.file("config", contents: "Include config\nInclude *\nHost loop-a\n  HostName github.com\n", mode: 0o600)
        _ = try directory.file("other", contents: "Include config\nHost loop-b\n", mode: 0o600)
        let parser = SSHConfigParser(sshDirectory: directory.url, homeDirectory: directory.url)
        let aliases = parser.parse(fileAt: directory.url.appendingPathComponent("config")).map(\.alias)
        #expect(Set(aliases) == ["loop-a", "loop-b"])
    }

    @Test func tildeIncludesAndMissingFiles() throws {
        let home = try TemporaryDirectory()
        _ = try home.file("extra.conf", contents: "Host from-home\n  HostName github.com\n", mode: 0o600)
        let parser = SSHConfigParser(sshDirectory: home.url.appendingPathComponent(".ssh"), homeDirectory: home.url)
        let entries = parser.parse(contents: "Include ~/extra.conf /nonexistent/*.conf\n", sourcePath: "inline")
        #expect(entries.map(\.alias) == ["from-home"])
        #expect(parser.parse(fileAt: home.url.appendingPathComponent("missing")).isEmpty)
    }

    @Test func tokenizer() {
        #expect(SSHConfigParser.split("Host a b\tc")?.arguments == ["a", "b", "c"])
        #expect(SSHConfigParser.split("HostName=github.com")?.keyword == "hostname")
        #expect(SSHConfigParser.split("HostName = github.com")?.arguments == ["github.com"])
        #expect(SSHConfigParser.split("IdentityFile \"~/.ssh/id work\"")?.arguments == ["~/.ssh/id work"])
        #expect(SSHConfigParser.split("Host")?.arguments == [])
    }

    @Test(arguments: [
        ("github.com", true), ("github-personal", true), ("gh_alt.2", true), ("A", true),
        ("-oProxyCommand", false), (".hidden", false), ("a b", false), ("a/b", false), ("", false),
        ("a;b", false), ("..", false), ("ali\u{202E}as", false), ("ñandu", false),
    ])
    func aliasValidation(alias: String, isValid: Bool) {
        #expect(SSHAliasValidator.isValid(alias) == isValid)
    }
}

@Suite("SSHAliasResolver")
struct SSHAliasResolverTests {
    private func resolver(_ runner: any CommandRunning) -> SSHAliasResolver {
        SSHAliasResolver(
            runner: runner,
            identity: TestValues.identity,
            shell: TestValues.shell,
            workingDirectory: TestValues.workingDirectory
        )
    }

    @Test func resolvesTheHostNameWithSSHG() async throws {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: ["-G"], with: .success(try Fixture.string("ssh/ssh-G-github-work.txt")))
        #expect(try await resolver(runner).resolveHostName(alias: "github-work") == "github.com")
        try await resolver(runner).requireGitHubAlias("github-work")
        let call = try #require(runner.invocations.first)
        #expect(call.executablePath == "/usr/bin/ssh")
        #expect(call.arguments == ["-G", "--", "github-work"])
        #expect(Set(call.environment.keys).isSubset(of: ProcessEnvironmentBuilder.sshAllowedKeys))
        #expect(call.timeout == Timeouts.sshVerify)
    }

    @Test func rejectsAliasesThatAreNotGitHub() async throws {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: ["-G"], with: .success("host work\nhostname gitlab.example.com\n"))
        await #expect(throws: GitError.aliasNotGitHub(hostName: "gitlab.example.com")) {
            try await resolver(runner).requireGitHubAlias("work")
        }
    }

    @Test func invalidAliasesNeverRun() async {
        let runner = FakeCommandRunner()
        await #expect(throws: GitError.invalidAlias) { try await resolver(runner).verify(alias: "-oProxyCommand=x") }
        await #expect(throws: GitError.invalidAlias) { try await resolver(runner).resolveHostName(alias: "a b") }
        #expect(runner.invocations.isEmpty)
    }

    @Test func verifyParsesTheGreeting() async throws {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: ["-T"], with: .failure(stderr: try Fixture.string("ssh/ssh-T-greeting.txt")))
        #expect(try await resolver(runner).verify(alias: "github-personal") == .authenticated(login: "user-a"))
        #expect(runner.invocations.first?.arguments
            == ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", "git@github-personal"])
    }

    @Test func verificationOutcomes() throws {
        typealias Resolver = SSHAliasResolver
        #expect(Resolver.classifyVerification(exitCode: 1, stderr: try Fixture.string("ssh/ssh-T-deploy-key.txt"), didTimeOut: false)
            == .failed(exitCode: 1), "a deploy key greets with owner/repo, not a login")
        #expect(Resolver.classifyVerification(exitCode: 255, stderr: "git@github.com: Permission denied (publickey).", didTimeOut: false)
            == .permissionDenied)
        #expect(Resolver.classifyVerification(exitCode: 255, stderr: "Host key verification failed.", didTimeOut: false)
            == .hostKeyUnknown)
        #expect(Resolver.classifyVerification(exitCode: 143, stderr: "", didTimeOut: true) == .timeout)
        #expect(Resolver.parseLogin(fromGreeting: "Hi -evil! You've successfully authenticated") == nil)
        #expect(Resolver.parseHostName(fromSSHConfigDump: "user git\nport 22\n") == nil)
    }

    /// Enterprise Managed User logins greet with their underscore (synthetic logins, v0.3.1).
    @Test(arguments: ["user1_acme", "user1-e_acme", "1234567_acme"])
    func managedUserGreetingsNameTheLogin(login: String) {
        let greeting = "Hi \(login)! You've successfully authenticated, but GitHub does not provide shell access."
        #expect(SSHAliasResolver.parseLogin(fromGreeting: greeting) == login)
        #expect(SSHAliasResolver.classifyVerification(exitCode: 1, stderr: greeting, didTimeOut: false) == .authenticated(login: login))
        #expect(SSHAliasResolver.parseLogin(fromGreeting: "Hi _\(login)! You've successfully authenticated") == nil)
    }
}

@Suite("GitService")
struct GitServiceTests {
    private func service(
        _ runner: any CommandRunning,
        clock: any VaultClock = ManualClock(),
        home: String? = nil,
        workingDirectory: URL = TestValues.workingDirectory
    ) -> GitService {
        var identity = TestValues.identity
        if let home {
            identity.home = home
        }
        return GitService(
            runner: runner,
            identity: identity,
            shell: ShellEnvironmentModel(path: GHConstants.systemPATH),
            workingDirectory: workingDirectory,
            clock: clock
        )
    }

    /// Simulates `git clone -- <url> <temp>` by creating `<-C dir>/<temp>`.
    private static func createCloneDirectory(_ spec: CommandSpec) {
        guard let cIndex = spec.arguments.firstIndex(of: "-C"), let temp = spec.arguments.last else { return }
        let folder = URL(fileURLWithPath: spec.arguments[cIndex + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent(temp), withIntermediateDirectories: false)
    }

    @Test func hardenedArguments() throws {
        #expect(GitService.hardenedArguments(directory: URL(fileURLWithPath: "/tmp/x")) == [
            "-c", "core.fsmonitor=", "-c", "core.hooksPath=/dev/null", "-c", "protocol.allow=never",
            "-c", "protocol.ssh.allow=always", "-C", "/tmp/x",
        ])
        #expect(GitService.cloneURL(alias: "github-personal", repo: try TestValues.repo()) == "git@github-personal:owner-a/repo-a.git")
    }

    @Test func cloneUsesATemporarySiblingThenRenames() async throws {
        let folder = try TemporaryDirectory()
        let runner = ClosureRunner { spec, _ in
            Self.createCloneDirectory(spec)
            return ClosureRunner.result()
        }
        let destination = try await service(runner).clone(repo: try TestValues.repo(), alias: "github-personal", into: folder.url)
        #expect(destination.path == folder.url.appendingPathComponent("repo-a").path)
        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        #expect(contents == ["repo-a"], "the temporary directory was renamed")
    }

    @Test func cloneArgv() async throws {
        let folder = try TemporaryDirectory()
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: [], with: .failure(exitCode: 1, stderr: "fatal: something"))
        await #expect(throws: GitError.commandFailed(exitCode: 1)) {
            try await service(runner).clone(repo: try TestValues.repo(), alias: "github-personal", into: folder.url)
        }
        let call = try #require(runner.invocations.first)
        #expect(call.executablePath == "/usr/bin/git")
        let args = call.arguments
        #expect(Array(args.prefix(10)) == GitService.hardenedArguments(directory: folder.url))
        #expect(args[10...].prefix(3) == ["clone", "--", "git@github-personal:owner-a/repo-a.git"])
        let temp = try #require(args.last)
        #expect(temp.hasPrefix(".repo-a.fxvault-clone-"))
        #expect(Set(call.environment.keys).isSubset(of: ProcessEnvironmentBuilder.gitAllowedKeys))
        #expect(call.environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(call.timeout == Timeouts.gitClone)
        #expect(runner.invocations.count == 1, "exit 1 is not retried")
    }

    @Test func exit128IsRetriedThreeTimes() async throws {
        let folder = try TemporaryDirectory()
        let clock = ManualClock()
        let runner = ClosureRunner { spec, call in
            if call <= Limits.cloneRetries {
                Self.createCloneDirectory(spec) // partial clone left behind
                return ClosureRunner.result(exitCode: 128, stderr: "fatal: the remote end hung up unexpectedly")
            }
            Self.createCloneDirectory(spec)
            return ClosureRunner.result()
        }
        let git = service(runner, clock: clock)
        let repo = try TestValues.repo()
        let folderURL = folder.url
        let task = Task { try await git.clone(repo: repo, alias: "github-personal", into: folderURL) }
        for _ in 0..<Limits.cloneRetries {
            await clock.waitForSleepers(count: 1)
            clock.advance(by: Timeouts.cloneRetryInterval)
        }
        _ = try await task.value
        #expect(runner.callCount == Limits.cloneRetries + 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["repo-a"])
    }

    @Test(arguments: [
        ("ERROR: Repository not found.\nfatal: Could not read from remote repository.", GitError.authenticationFailed),
        ("git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.", GitError.authenticationFailed),
        ("Host key verification failed.\nfatal: Could not read from remote repository.", GitError.hostKeyVerificationFailed),
        ("fatal: could not create work tree dir 'x': Operation not permitted", GitError.folderAccessDenied),
    ])
    func permanentCloneFailuresAreNotRetried(stderr: String, expected: GitError) async throws {
        let folder = try TemporaryDirectory()
        let runner = ClosureRunner { spec, _ in
            Self.createCloneDirectory(spec)
            return ClosureRunner.result(exitCode: 128, stderr: stderr)
        }
        await #expect(throws: expected) {
            try await service(runner).clone(repo: try TestValues.repo(), alias: "github-personal", into: folder.url)
        }
        #expect(runner.callCount == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).isEmpty, "only the temp dir is removed")
    }

    @Test func existingDestinationFailsEarly() async throws {
        let folder = try TemporaryDirectory()
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("repo-a"), withIntermediateDirectories: false)
        let runner = FakeCommandRunner()
        await #expect(throws: GitError.destinationExists) {
            try await service(runner).clone(repo: try TestValues.repo(), alias: "github-personal", into: folder.url)
        }
        await #expect(throws: GitError.invalidAlias) {
            try await service(runner).clone(repo: try TestValues.repo(), alias: "-oProxyCommand=x", into: folder.url)
        }
        #expect(runner.invocations.isEmpty)
    }

    @Test(arguments: ["../outside", "/etc/passwd", "a/../../b", "a//b", "a\u{0}b"])
    func relativePathsCannotEscape(path: String) {
        #expect(throws: GitError.self) { try GitService.validatedRelativePath(path) }
    }

    @Test func realRepositoryChecks() async throws {
        let home = try TemporaryDirectory()
        let repository = try TemporaryDirectory()
        let runner = ProcessRunner()
        let git = service(runner, clock: SystemClock(), home: home.url.path, workingDirectory: home.url)
        #expect(try await git.repositoryRoot(containing: repository.url) == nil, "not a repository yet")

        let environment = ProcessEnvironmentBuilder.git(
            identity: ProcessIdentityModel(home: home.url.path, user: "user-a", temporaryDirectory: home.url.path),
            shell: ShellEnvironmentModel(path: GHConstants.systemPATH)
        )
        func runGit(_ arguments: [String]) async throws -> CommandResult {
            try await runner.run(CommandSpec(
                executableURL: URL(fileURLWithPath: GHConstants.gitPath),
                arguments: ["-C", repository.url.path] + arguments,
                environment: environment,
                workingDirectory: repository.url,
                timeout: .seconds(30)
            ))
        }
        #expect(try await runGit(["init", "-q"]).exitCode == 0)
        _ = try repository.file(".gitignore", contents: ".env\n", mode: 0o644)
        _ = try repository.file(".env", contents: "FXV_FIXTURE=1\n", mode: 0o600)
        let subdirectory = repository.url.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: false)
        try Data("FXV_FIXTURE=2\n".utf8).write(to: subdirectory.appendingPathComponent("app.env"))
        #expect(try await runGit(["add", "config/app.env"]).exitCode == 0)

        #expect(try await git.repositoryRoot(containing: subdirectory)?.path == repository.url.path)
        #expect(try await git.isIgnored(relativePath: ".env", inRepository: repository.url))
        #expect(!(try await git.isIgnored(relativePath: "config/app.env", inRepository: repository.url)))
        #expect(try await git.isTracked(relativePath: "config/app.env", inRepository: repository.url))
        #expect(!(try await git.isTracked(relativePath: ".env", inRepository: repository.url)))
    }
}

@Suite("EmptyWorkingDirectory")
struct EmptyWorkingDirectoryTests {
    @Test func createsAPrivateDirectory() throws {
        let caches = try TemporaryDirectory()
        let directory = try EmptyWorkingDirectory.prepare(in: caches.url)
        #expect(directory.path == caches.url.appendingPathComponent("io.fractalx.fxvault/empty-cwd").path)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try EmptyWorkingDirectory.prepare(in: caches.url) == directory, "idempotent")
    }

    @Test func refusesASymlink() throws {
        let caches = try TemporaryDirectory()
        let elsewhere = try TemporaryDirectory()
        let parent = caches.url.appendingPathComponent("io.fractalx.fxvault")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: parent.appendingPathComponent("empty-cwd"), withDestinationURL: elsewhere.url)
        #expect(throws: GHError.launchFailed) { try EmptyWorkingDirectory.prepare(in: caches.url) }
    }
}
