import EnvTools
import Foundation
import GitHubKit
import VaultCore
import VaultData
@testable import FXVault

/// A scripted `GitignoreChecker` (§8 D4–D6): no git process runs in AppTests.
struct FakeGitignoreChecker: GitignoreChecker {
    enum Answer: Sendable {
        /// `rev-parse` finds no work tree.
        case outsideRepository
        /// Inside `root`; `isTracked` and `isIgnored` answer as given.
        case repository(root: URL, isTracked: Bool, isIgnored: Bool)
        /// Every question fails (git missing, hardened flags rejected, ...).
        case failure
    }

    struct CheckFailed: Error {}

    let answer: Answer

    func repositoryRoot(containing directory: URL) async throws -> URL? {
        switch answer {
        case .outsideRepository: nil
        case .repository(let root, _, _): root
        case .failure: throw CheckFailed()
        }
    }

    func isIgnored(relativePath: String, inRepositoryAt root: URL) async throws -> Bool {
        guard case .repository(_, _, let isIgnored) = answer else { throw CheckFailed() }
        return isIgnored
    }

    func isTracked(relativePath: String, inRepositoryAt root: URL) async throws -> Bool {
        guard case .repository(_, let isTracked, _) = answer else { throw CheckFailed() }
        return isTracked
    }
}

/// Fixtures shared by the `.env` import and export suites (synthetic values only, lessons.md).
enum EnvFileFixtures {
    static let secretValue = "FXV_FIXTURE_SECRET_VALUE"
    static let variableValue = "https://example.test/app"
    static let ownerOnlyMode = 0o600

    /// The package's synthetic 12-line `sample.env` (M5 verify: pre-marks secrets, suggests fixes).
    static var sampleEnvURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Packages/FXVaultKit/Tests/EnvToolsTests/Fixtures/sample.env")
    }

    /// Value fragments of `sample.env` that must never appear in rows, issues or summaries.
    static let sampleValueFragments = ["not-a-password", "sample-key-value", "MIIBsample", "deploy-bot", "fx-sample-override"]

    /// An `EnvFileRepository` over the harness vault with scripted git answers and an iCloud
    /// detector rooted in the sandbox (`<sandbox>/home/Library/Mobile Documents` syncs).
    @MainActor
    static func repository(_ harness: TestHarness, git: FakeGitignoreChecker.Answer = .outsideRepository) -> EnvFileRepository {
        EnvFileRepository(
            session: harness.data.session,
            gitignoreChecker: FakeGitignoreChecker(answer: git),
            cloudSyncDetector: CloudSyncDetector(homeDirectory: home(of: harness), isUbiquitous: { _ in false }),
            clock: harness.clock
        )
    }

    @MainActor
    static func home(of harness: TestHarness) -> URL {
        harness.sandbox.appending(path: "home", directoryHint: .isDirectory)
    }

    /// Creates `directory` (and parents) and returns it.
    @discardableResult
    static func makeDirectory(_ directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The items of one scope, read now (first emission of the observation).
    @MainActor
    static func items(_ harness: TestHarness, repositoryID: RepoID, scope: ConfigScope = .repository) async throws -> [ConfigItemModel] {
        for try await items in harness.data.config.observeItems(repositoryID: repositoryID, scope: scope) {
            return items.filter { !$0.isDeleted }
        }
        return []
    }

    /// The decrypted value of `name` in `scope` (tests only).
    @MainActor
    static func value(
        _ harness: TestHarness,
        repositoryID: RepoID,
        scope: ConfigScope = .repository,
        kind: ConfigKind,
        name: String
    ) async throws -> String? {
        let items = try await items(harness, repositoryID: repositoryID, scope: scope)
        guard let item = items.first(where: { $0.kind == kind && $0.name == name }) else { return nil }
        let value = try harness.data.config.reveal(item.id)
        defer { value.wipe() }
        return value.utf8String()
    }

    /// Imports `Example-Org/example-repo` through the scripted gh: one secret GitHub never returns
    /// a value for (`MISSING_SECRET`, value missing, §7.8) and one variable with a value.
    @MainActor
    static func importRepositoryWithMissingSecret(_ harness: TestHarness) async throws -> RepoID {
        try harness.installFakeGH()
        harness.stubAuthStatus(TestFixtures.authStatusTwoAccounts)
        harness.stubToken()
        harness.runner.stub(
            argumentsPrefix: ["repo", "view"],
            with: .success(TestFixtures.repoJSON(owner: TestFixtures.owner, name: TestFixtures.repoName, permission: "ADMIN"))
        )
        harness.runner.stub(
            argumentsPrefix: ["secret", "list"],
            with: .success(#"[{"name":"MISSING_SECRET","updatedAt":"2026-01-02T03:04:05Z"}]"#)
        )
        harness.runner.stub(
            argumentsPrefix: ["variable", "list"],
            with: .success(
                #"[{"name":"PUBLIC_URL","value":"\#(variableValue)","updatedAt":"2026-01-02T03:04:05Z","createdAt":"2026-01-02T03:04:05Z"}]"#
            )
        )
        harness.runner.stub(argumentsPrefix: ["api"], with: .success(#"[{"total_count":0,"environments":[]}]"#))
        await harness.app.refreshGHStatus()
        let ref = try GHRepoRef(owner: TestFixtures.owner, name: TestFixtures.repoName)
        let result = try await harness.data.catalog.importRepository(ref, accountLogin: TestFixtures.account)
        return result.repository.id
    }
}
