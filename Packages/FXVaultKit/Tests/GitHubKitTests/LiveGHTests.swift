import CryptoKit
import Foundation
import Testing
@testable import GitHubKit
import VaultCore

@Suite("Fixtures")
struct FixturesBundleTests {
    @Test func fixturesAreBundled() throws {
        #expect(Bundle.module.url(forResource: "Fixtures", withExtension: nil) != nil)
        #expect(try Fixture.data("gh/stderr-cases.json").count > 0)
    }

    /// Fixtures are public: no real organization, account or team identifiers (§12.4).
    /// The denylist holds SHA-256 digests of lowercase tokens, so the names themselves never
    /// appear in this public repository. Text is split on every non-alphanumeric character,
    /// so `admin-<org>` and `io.<org>.app` are caught by the `<org>` token.
    @Test func fixturesContainNoDenylistedNames() throws {
        let root = try Fixture.url("")
        let denylist: Set<String> = [
            "ebb0e3e2cc2dc56d551d1c322fc4f3529dac4af26a3ac4a0297f7cb26fdc85fa",
            "27a65e66023ac5352761e5a0db80610c1580ab00f412208b22207f641140d374",
            "177ff24b4b08dbfb272041d7775e0f9aa7c348febdd2218020c6da095366479d",
            "f263381b69af1d6ae42178afb730c406f53075505873c5437293234376d39e21",
        ]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        for file in files where !file.hasDirectoryPath {
            let text = String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self).lowercased()
            let tokens = Set(text.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
            for token in tokens {
                let digest = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
                #expect(!denylist.contains(digest), "\(file.lastPathComponent) contains a denylisted name")
            }
        }
    }

    /// The digest check itself works: a known non-secret token is found by the same routine.
    @Test func denylistDigestsMatchLowercaseTokens() {
        let digest = SHA256.hash(data: Data("octocat".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == Self.octocatDigest)
    }

    private static let octocatDigest = "a6658157f0df83900a6c8f3b34a7c739c66455d34b142846c96dedcacda08a3c"
}

/// Read-only calls against the real gh, for a manual check on a developer Mac:
/// `FXV_LIVE_GH=1 swift test --filter LiveGHTests`. Never enabled in CI. Runs only `gh --version`,
/// `gh auth status/token`, `gh repo view` and `gh api -X GET` on the public `cli/cli` repository.
/// No assertion ever includes a token or value, so nothing secret can reach the test log.
@Suite(
    "Live gh (read-only, opt-in)",
    .enabled(if: ProcessInfo.processInfo.environment["FXV_LIVE_GH"] == "1"),
    .serialized
)
struct LiveGHTests {
    private static let publicRepo = ("cli", "cli")
    private let workspace: TemporaryDirectory

    init() throws {
        workspace = try TemporaryDirectory()
    }

    private func stack() async throws -> (GHAuthService, GHCommandScheduler?) {
        let runner = ProcessRunner()
        let identity = ProcessIdentityModel.current()
        let workingDirectory = try EmptyWorkingDirectory.prepare(in: workspace.url)
        let shell = try await ShellEnvironmentResolver(
            runner: runner,
            identity: identity,
            workingDirectory: workingDirectory
        ).resolve()
        let installation = try await GHLocator(runner: runner, identity: identity, workingDirectory: workingDirectory)
            .locate(overridePath: nil, shell: shell)
        #expect(installation.version.isSupported)
        let service = GHCommandService(
            installation: installation,
            identity: identity,
            shell: shell,
            workingDirectory: workingDirectory,
            runner: runner
        )
        let auth = GHAuthService(service: service, tokenCache: GHTokenCache())
        let accounts = try await auth.accounts()
        guard let active = accounts.first(where: \.isActive) else { return (auth, nil) }
        return (auth, GHCommandScheduler(accountLogin: active.login, service: service, auth: auth, clock: SystemClock()))
    }

    @Test func readOnlyRoundTrip() async throws {
        let (auth, maybeScheduler) = try await stack()
        let scheduler = try #require(maybeScheduler, "no active gh account")
        let repo = try GHRepoRef(owner: Self.publicRepo.0, name: Self.publicRepo.1)

        let view = try await scheduler.viewRepository(repo)
        #expect(view.repoRef == repo)

        let environments = try await scheduler.listEnvironments(repo)
        #expect(!environments.isEmpty)
        if let first = environments.first {
            let single = try await scheduler.environment(repo, named: first.name)
            #expect(single?.id == first.id)
        }
        #expect(try await scheduler.environment(repo, named: "fxvault-nonexistent-environment") == nil)

        await #expect(throws: GHError.writeAccessRequired) { try await scheduler.listSecrets(repo) }
        #expect(!(try await scheduler.licenseTemplates()).isEmpty)
        auth.tokenCache.purge()
        #expect(auth.tokenCache.count == 0)
    }
}
