import Foundation
import GitHubKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Shared fixtures of the ItemEditor and Environment suites: a staged repository (never on
/// GitHub, viewer treated as admin) and an imported one (synced environments and items, through
/// the scripted gh). Synthetic names and `FXV_FIXTURE_*` values only (lessons.md).
@MainActor
enum EditorFixtures {
    static let owner = TestFixtures.owner
    static let repoName = TestFixtures.repoName
    static var fullName: String {
        "\(owner)/\(repoName)"
    }

    static let secretValue = "FXV_FIXTURE_SECRET_VALUE"
    static let variableValue = "https://example.invalid/api"
    static let regionValue = "FXV_FIXTURE_REGION"
    static let modeValue = "FXV_FIXTURE_MODE"

    /// A PEM-shaped value with a trailing newline (D32). Synthetic; not a key.
    static let pemValue = "-----BEGIN KEY-----\nFXVFIXTURE\n-----END KEY-----\n"

    /// A URL with userinfo, assembled at run time so secret scanners do not flag the source.
    static var urlWithCredentials: String {
        "postgres://" + "fixture-user" + ":" + "FXV_FIXTURE_PW" + "@db.example.invalid/app"
    }

    // MARK: - Staged repository

    /// An unlocked harness with a staged repository: repository secret `API_TOKEN`, variable
    /// `BASE_URL`, environment `staging` with secret `STAGING_TOKEN`.
    static func stagedHarness() async throws -> (TestHarness, RepoID) {
        let harness = try await TestHarness(vault: .unlocked)
        let id = try await harness.stageRepository(
            items: [
                TestFixtures.item(.secret, "API_TOKEN", secretValue),
                TestFixtures.item(.variable, "BASE_URL", variableValue),
            ],
            environments: [
                RepoCreationEnvironmentDraftModel(
                    name: "staging",
                    items: [TestFixtures.item(.secret, "STAGING_TOKEN", secretValue)]
                ),
            ]
        )
        return (harness, id)
    }

    // MARK: - Imported repository (scripted gh)

    /// Two environments: `production` (custom policy `release/*` plus a reviewer rule) and
    /// `staging` (all branches).
    static let environmentsJSON = """
    [{"total_count":2,"environments":[
     {"id":101,"name":"production","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z",
      "protection_rules":[{"id":9001,"type":"required_reviewers","reviewers":[]},{"id":9002,"type":"branch_policy"}],
      "deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}},
     {"id":102,"name":"staging","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z",
      "protection_rules":[],"deployment_branch_policy":null}]}]
    """

    static let branchPoliciesJSON = """
    [{"total_count":1,"branch_policies":[{"id":361471,"name":"release/*","type":"branch"}]}]
    """

    static func secretsJSON(_ names: [String]) -> String {
        "[" + names.map { #"{"name":"\#($0)","updatedAt":"2026-10-01T10:00:00.123Z"}"# }.joined(separator: ",") + "]"
    }

    static func variablesJSON(_ entries: [(name: String, value: String)]) -> String {
        "[" + entries.map {
            #"{"createdAt":"2026-09-01T08:00:00Z","name":"\#($0.name)","updatedAt":"2026-09-02T08:00:00Z","value":"\#($0.value)"}"#
        }.joined(separator: ",") + "]"
    }

    /// An unlocked harness with `Example-Org/example-repo` imported through the scripted gh:
    /// - repository: secret `API_TOKEN` (value missing), variable `BASE_URL`
    /// - `production`: secret `DEPLOY_KEY` (value missing), variable `REGION`
    /// - `staging`: variable `MODE`
    ///
    /// - Parameter permission: gh `viewerPermission` (`ADMIN`, or `WRITE` for a read-only vault row).
    static func importedHarness(permission: String = "ADMIN") async throws -> (TestHarness, RepoID) {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        try harness.installFakeGH()
        harness.stubAuthStatus(TestFixtures.authStatusTwoAccounts)
        harness.stubToken()
        await harness.app.refreshGHStatus()

        let repo = fullName
        let runner = harness.runner
        runner.enqueue(
            .success(TestFixtures.repoJSON(owner: owner, name: repoName, permission: permission)),
            matching: { $0.starts(with: ["repo", "view", repo]) }
        )
        runner.enqueue(
            .success(environmentsJSON),
            matching: { $0.first == "api" && $0.contains("repos/\(repo)/environments?per_page=100") }
        )
        runner.enqueue(
            .success(branchPoliciesJSON),
            matching: { arguments in
                arguments.first == "api"
                    && arguments.contains { $0.hasPrefix("repos/\(repo)/environments/production/deployment-branch-policies") }
            }
        )
        runner.enqueue(.success(secretsJSON(["API_TOKEN"])), matching: listMatcher("secret", environment: nil))
        runner.enqueue(.success(secretsJSON(["DEPLOY_KEY"])), matching: listMatcher("secret", environment: "production"))
        runner.enqueue(.success(secretsJSON([])), matching: listMatcher("secret", environment: "staging"))
        runner.enqueue(
            .success(variablesJSON([(name: "BASE_URL", value: variableValue)])),
            matching: listMatcher("variable", environment: nil)
        )
        runner.enqueue(
            .success(variablesJSON([(name: "REGION", value: regionValue)])),
            matching: listMatcher("variable", environment: "production")
        )
        runner.enqueue(
            .success(variablesJSON([(name: "MODE", value: modeValue)])),
            matching: listMatcher("variable", environment: "staging")
        )
        let result = try await harness.data.catalog.importRepository(
            GHRepoRef(owner: owner, name: repoName),
            accountLogin: TestFixtures.account
        )
        #expect(result.unreadable.isEmpty)
        return (harness, result.repository.id)
    }

    private static func listMatcher(_ noun: String, environment: String?) -> FakeCommandRunner.Matcher {
        let repoFlag = "--repo=\(fullName)"
        return { arguments in
            guard arguments.starts(with: [noun, "list", repoFlag]) else { return false }
            let envFlag = arguments.first { $0.hasPrefix("--env=") }
            return envFlag == environment.map { "--env=\($0)" }
        }
    }

    // MARK: - Reads

    /// The items of one scope, now.
    static func items(_ harness: TestHarness, _ id: RepoID, scope: ConfigScope = .repository) async throws -> [ConfigItemModel] {
        try await harness.data.config.editorItems(repositoryID: id, scope: scope)
    }

    static func item(
        _ harness: TestHarness,
        _ id: RepoID,
        named name: String,
        scope: ConfigScope = .repository
    ) async throws -> ConfigItemModel {
        try #require(try await items(harness, id, scope: scope).first { $0.name == name && !$0.isDeleted })
    }

    static func environment(_ harness: TestHarness, _ id: RepoID, named name: String) throws -> EnvironmentModel {
        try #require(try harness.data.config.scopes(repositoryID: id).compactMap(\.environment).first {
            $0.name == name && !$0.isDeleted
        })
    }

    /// The decrypted value of an item (test only).
    static func revealed(_ harness: TestHarness, _ itemID: ConfigItemID) throws -> String? {
        let bytes = try harness.data.config.reveal(itemID)
        defer { bytes.wipe() }
        return bytes.utf8String()
    }

    static func pendingCount(_ harness: TestHarness, _ id: RepoID) throws -> Int {
        try harness.data.config.pendingCounts().counts(for: id).pending
    }
}
