import Darwin
import Foundation
import GitHubKit
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// gh detection, accounts, tokens, queues and SSH aliases (M2) with a scripted runner.
@Suite("GitHubEnvironmentRepository")
struct GitHubEnvironmentTests {
    static let authStatus = """
    {"hosts":{"github.com":[
     {"state":"success","active":true,"host":"github.com","login":"user-a","tokenSource":"keyring","scopes":"gist, read:org, repo","gitProtocol":"ssh"},
     {"state":"success","active":false,"host":"github.com","login":"user-b","tokenSource":"keyring","scopes":"gist","gitProtocol":"ssh"}
    ],"ghe.example.com":[
     {"state":"success","active":true,"host":"ghe.example.com","login":"user-z","tokenSource":"keyring","scopes":"repo","gitProtocol":"https"}
    ]}}
    """
    static let onlyUserA = """
    {"hosts":{"github.com":[
     {"state":"success","active":true,"host":"github.com","login":"user-a","tokenSource":"keyring","scopes":"read:org, repo","gitProtocol":"ssh"}
    ]}}
    """
    static let alias = "github-personal"
    static let executableMode: mode_t = S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH

    /// A repository over a fake gh binary in a temporary folder.
    struct Fixture {
        let directory: ConfigTempDirectory
        let ghPath: String
        let runner = FakeCommandRunner()
        let database: VaultDatabase
        let clock = ManualClock()
        let repository: GitHubEnvironmentRepository

        init(version: String = "2.97.0") throws {
            directory = try ConfigTempDirectory()
            let gh = directory.file("gh")
            try Data("#!/bin/sh\n".utf8).write(to: gh)
            guard chmod(gh.path, GitHubEnvironmentTests.executableMode) == 0 else { throw CocoaError(.fileWriteNoPermission) }
            ghPath = gh.path
            database = try DatabaseFactory.inMemory()
            let sshDirectory = directory.url.appendingPathComponent("ssh", isDirectory: true)
            try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
            try Data("Host \(GitHubEnvironmentTests.alias)\n  HostName github.com\n  User git\nHost *\n  ServerAliveInterval 30\n".utf8)
                .write(to: sshDirectory.appendingPathComponent("config"))
            runner.stub(argumentsPrefix: ["--version"], with: .success("gh version \(version) (2026-09-01)\nhttps://github.com/cli/cli/releases/tag/v\(version)\n"))
            runner.stub(argumentsPrefix: ["auth", "token"], with: .success(ConfigFixture.token + "\n"))
            repository = GitHubEnvironmentRepository(
                database: database,
                runner: runner,
                identity: GHFixtures.identity,
                workingDirectory: GHFixtures.workingDirectory,
                clock: clock,
                shellPath: "/bin/zsh",
                sshConfigParser: SSHConfigParser(sshDirectory: sshDirectory, homeDirectory: directory.url)
            )
        }
    }

    // MARK: - Detection

    @Test func detectsATrustedGHAtTheFloor() async throws {
        let fixture = try Fixture()
        defer { fixture.directory.remove() }
        let installation = try await fixture.repository.detectGH(overridePath: fixture.ghPath)
        #expect(installation.version == GHVersion.minimum)
        #expect(await fixture.repository.installation == installation)
        // The shell probe ran (and found nothing in the fake), then gh --version.
        #expect(fixture.runner.invocations.contains { $0.arguments == ["--version"] })
    }

    @Test func rejectsAnOldOrMissingGH() async throws {
        let old = try Fixture(version: "2.96.9")
        defer { old.directory.remove() }
        let error = await environmentError { _ = try await old.repository.detectGH(overridePath: old.ghPath) }
        #expect(error == .github(.versionTooOld(found: GHVersion(major: 2, minor: 96, patch: 9), required: .minimum)))
        #expect(await old.repository.installation == nil)

        let missing = await environmentError { _ = try await old.repository.detectGH(overridePath: old.directory.file("absent").path) }
        #expect(missing == .github(.notInstalled))
    }

    // MARK: - Accounts and tokens

    @Test func accountsArePersistedWithScopes() async throws {
        let fixture = try Fixture()
        defer { fixture.directory.remove() }
        #expect(await environmentError { _ = try await fixture.repository.accounts() } == .github(.notInstalled))
        try await fixture.repository.detectGH(overridePath: fixture.ghPath)
        fixture.runner.enqueue(.success(Self.authStatus), matching: { $0.starts(with: ["auth", "status"]) })

        let accounts = try await fixture.repository.accounts()
        #expect(accounts.map(\.account.login) == ["user-a", "user-b"])
        #expect(accounts[0].status?.scopes == .ok)
        #expect(accounts[1].status?.scopes == .missing(["repo", "read:org"]))
        #expect(await fixture.repository.scopeFixCommands(for: "user-b") == [
            "gh auth switch -h github.com -u user-b",
            "gh auth refresh -h github.com -s repo,read:org",
            "gh auth switch -h github.com -u user-a",
        ])

        // A login gh no longer lists stays, marked absent.
        fixture.runner.enqueue(.success(Self.onlyUserA), matching: { $0.starts(with: ["auth", "status"]) })
        let again = try await fixture.repository.recheck(login: "user-a")
        #expect(again.map(\.account.login) == ["user-a", "user-b"])
        #expect(again[1].isLoggedIn == false)
        #expect(again[1].account.isPresent == false)
        #expect(try AccountStore(database: fixture.database).fetch(login: "USER-B")?.isPresent == false)
    }

    @Test func schedulersArePerAccountAndTokensPurgeSynchronously() async throws {
        let fixture = try Fixture()
        defer { fixture.directory.remove() }
        #expect(await schedulerError(fixture.repository, login: "user-a") == .notInstalled)
        try await fixture.repository.detectGH(overridePath: fixture.ghPath)
        // One write ten minutes ago in the journal seeds the throttle.
        let tenMinutes: TimeInterval = 600
        try SyncJournalStore(database: fixture.database).append(SyncJournalRecord(
            runID: SyncRunID(),
            accountLogin: "USER-A",
            repositoryID: nil,
            op: "set_secret",
            command: "secret.set",
            isWrite: true,
            scopeLabel: "repo",
            targetKey: "repo",
            state: .succeeded,
            startedAt: fixture.clock.now.addingTimeInterval(-tenMinutes)
        ))

        let first = try await fixture.repository.scheduler(for: "user-a")
        #expect(await first.writesInLastHour == Limits.defaultWriteCost)
        let same = try await fixture.repository.scheduler(for: "USER-A")
        #expect(first === same)
        #expect(try await fixture.repository.scheduler(for: "user-b") !== first)

        fixture.runner.enqueue(.success("org-a\n"), matching: { $0.starts(with: ["org", "list"]) })
        #expect(try await first.listOrganizations() == ["org-a"])
        #expect(fixture.repository.tokenCache.count == 1)
        fixture.repository.purgeTokens()
        #expect(fixture.repository.tokenCache.count == 0)
    }

    // MARK: - SSH aliases

    @Test func aliasesAreListedMappedAndVerified() async throws {
        let fixture = try Fixture()
        defer { fixture.directory.remove() }
        #expect(fixture.repository.sshHostEntries().map(\.alias) == [Self.alias])
        try AccountStore(database: fixture.database).save(AccountModel(login: "user-a", lastSeenAt: fixture.clock.now))

        let mapped = try await fixture.repository.mapSSHAlias(Self.alias, to: "user-a")
        #expect(mapped.sshHostAlias == Self.alias)
        #expect(await environmentError { _ = try await fixture.repository.mapSSHAlias("-oProxyCommand", to: "user-a") } == .ssh(.invalidAlias))
        #expect(await environmentError { _ = try await fixture.repository.mapSSHAlias(Self.alias, to: "user-x") } == .accountNotFound)

        fixture.runner.enqueue(.success("hostname github.com\nuser git\n"), matching: { $0 == ["-G", "--", Self.alias] })
        fixture.runner.enqueue(
            .failure(stderr: "Hi user-a! You've successfully authenticated, but GitHub does not provide shell access.\n"),
            matching: { $0.first == "-T" }
        )
        let verified = try await fixture.repository.testSSHAlias(Self.alias, for: "user-a")
        #expect(verified == .authenticatedAsAccount(login: "user-a"))
        let stored = try #require(try AccountStore(database: fixture.database).fetch(login: "user-a"))
        #expect(stored.isSSHAliasVerified)
        #expect(stored.sshVerifiedAt == fixture.clock.now)

        // Another account's key, not logged into gh: the verification is cleared.
        fixture.runner.enqueue(.success("hostname github.com\n"), matching: { $0 == ["-G", "--", Self.alias] })
        fixture.runner.enqueue(.failure(stderr: "Hi user-q! You've successfully authenticated.\n"), matching: { $0.first == "-T" })
        let other = try await fixture.repository.testSSHAlias(Self.alias, for: "user-a")
        #expect(other == .authenticatedAsOtherAccount(login: "user-q", isLoggedIntoGH: false))
        #expect(try AccountStore(database: fixture.database).fetch(login: "user-a")?.isSSHAliasVerified == false)

        fixture.runner.enqueue(.success("hostname gitlab.example\n"), matching: { $0 == ["-G", "--", Self.alias] })
        #expect(try await fixture.repository.testSSHAlias(Self.alias, for: "user-a") == .notGitHub(hostName: "gitlab.example"))

        fixture.runner.enqueue(.success("hostname github.com\n"), matching: { $0 == ["-G", "--", Self.alias] })
        fixture.runner.enqueue(.failure(exitCode: 255, stderr: "git@github.com: Permission denied (publickey).\n"), matching: { $0.first == "-T" })
        #expect(try await fixture.repository.testSSHAlias(Self.alias, for: "user-a") == .permissionDenied)

        try await fixture.repository.mapSSHAlias(nil, to: "user-a")
        #expect(try AccountStore(database: fixture.database).fetch(login: "user-a")?.sshHostAlias == nil)
    }

    // MARK: - Helpers

    private func environmentError(_ body: () async throws -> Void) async -> GitHubEnvironmentError? {
        do {
            try await body()
            return nil
        } catch let error as GitHubEnvironmentError {
            return error
        } catch {
            Issue.record("Expected a GitHubEnvironmentError, got \(error)")
            return nil
        }
    }

    private func schedulerError(_ repository: GitHubEnvironmentRepository, login: String) async -> GHError? {
        do {
            _ = try await repository.scheduler(for: login)
            return nil
        } catch {
            return error
        }
    }
}
