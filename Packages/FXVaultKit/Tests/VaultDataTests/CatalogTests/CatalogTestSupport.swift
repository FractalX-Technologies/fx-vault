import Foundation
import GitHubKit
import os
import Testing
import VaultCore
@testable import VaultData

/// Sanitized gh output in the shapes of `Tests/GitHubKitTests/Fixtures` (§12.4): placeholder
/// owners and names, synthetic `FXV_FIXTURE_*` values.
enum GHFixtures {
    static let identity = ProcessIdentityModel(
        home: "/Users/user-a",
        user: "user-a",
        temporaryDirectory: "/private/tmp/fxvault-tests"
    )
    static let workingDirectory = URL(fileURLWithPath: "/private/tmp/fxvault-tests/empty-cwd", isDirectory: true)
    static let ghURL = URL(fileURLWithPath: "/nonexistent/fxvault-tests/gh")

    static func repoJSON(
        owner: String,
        name: String,
        permission: String = "ADMIN",
        isArchived: Bool = false,
        nodeID: String? = nil
    ) -> String {
        """
        {"createdAt":"2026-01-02T03:04:05Z","defaultBranchRef":{"name":"main"},"id":"\(nodeID ?? "R_\(owner)_\(name)")",\
        "isArchived":\(isArchived),"isFork":false,"isPrivate":true,"name":"\(name)","nameWithOwner":"\(owner)/\(name)",\
        "owner":{"id":"O_\(owner)","login":"\(owner)"},"sshUrl":"git@github.com:\(owner)/\(name).git",\
        "viewerCanAdminister":\(permission == "ADMIN"),"viewerPermission":"\(permission)","visibility":"PRIVATE"}
        """
    }

    static func repoList(owner: String, names: [String]) -> String {
        "[" + names.map { repoJSON(owner: owner, name: $0) }.joined(separator: ",") + "]"
    }

    /// Two pages: `production` (custom policy, a reviewer rule) and `staging` (all branches),
    /// then an environment whose name the vault rejects.
    static let environments = """
    [{"total_count":3,"environments":[
     {"id":101,"name":"production","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z",
      "protection_rules":[{"id":9001,"type":"required_reviewers","reviewers":[]},{"id":9002,"type":"branch_policy"}],
      "deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}},
     {"id":102,"name":"staging","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z",
      "protection_rules":[],"deployment_branch_policy":null}]},
     {"total_count":3,"environments":[
     {"id":103,"name":"..","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z",
      "protection_rules":[],"deployment_branch_policy":null}]}]
    """

    static let branchPolicies = """
    [{"total_count":2,"branch_policies":[{"id":361471,"name":"release/*","type":"branch"},{"id":361472,"name":"v*","type":"tag"}]}]
    """

    static func secrets(_ names: [String]) -> String {
        "[" + names.map { #"{"name":"\#($0)","updatedAt":"2026-10-01T10:00:00.123456789Z"}"# }.joined(separator: ",") + "]"
    }

    /// `values` are JSON string literal bodies (already escaped).
    static func variables(_ entries: [(name: String, value: String)]) -> String {
        "[" + entries.map {
            #"{"createdAt":"2026-09-01T08:00:00Z","name":"\#($0.name)","updatedAt":"2026-09-02T08:00:00Z","value":"\#($0.value)"}"#
        }.joined(separator: ",") + "]"
    }

    static let adminRequired = "failed to get secrets: HTTP 403: Must have admin rights to Repository. (https://api.github.com/repos/owner-a/repo-a/actions/secrets?per_page=100)\n"
    static let saml = "GraphQL: Resource protected by organization SAML enforcement. You must grant your OAuth token access to this organization. See https://github.com/orgs/org-b/sso?authorization_request=FIXTURE (organization)\n"
    static let notFound = "GraphQL: Could not resolve to a Repository with the name 'owner-z/repo-z'. (repository)\n"
}

/// Matchers for scripted gh calls.
enum GHArgv {
    static func isRepoView(_ fullName: String) -> FakeCommandRunner.Matcher {
        { $0.starts(with: ["repo", "view", fullName]) }
    }

    static func isRepoList(_ owner: String) -> FakeCommandRunner.Matcher {
        { $0.starts(with: ["repo", "list", owner]) }
    }

    static func isEnvironmentList(_ fullName: String) -> FakeCommandRunner.Matcher {
        { $0.first == "api" && $0.contains("repos/\(fullName)/environments?per_page=100") }
    }

    static func isBranchPolicyList(_ fullName: String, environment: String) -> FakeCommandRunner.Matcher {
        { $0.first == "api" && $0.contains { $0.hasPrefix("repos/\(fullName)/environments/\(environment)/deployment-branch-policies") } }
    }

    static func isList(_ noun: String, repo fullName: String, environment: String?) -> FakeCommandRunner.Matcher {
        { arguments in
            guard arguments.starts(with: [noun, "list", "--repo=\(fullName)"]) else { return false }
            let envFlag = arguments.first { $0.hasPrefix("--env=") }
            return envFlag == environment.map { "--env=\($0)" }
        }
    }
}

/// Hands out schedulers over a ``FakeCommandRunner`` (no real gh, no real tokens).
struct FakeSchedulerProvider: GHSchedulerProviding {
    let runner: FakeCommandRunner
    let clock: ManualClock
    let tokenCache = GHTokenCache()

    init(runner: FakeCommandRunner = FakeCommandRunner(), clock: ManualClock = ManualClock()) {
        self.runner = runner
        self.clock = clock
        runner.stub(argumentsPrefix: ["auth", "token"], with: .success(ConfigFixture.token + "\n"))
    }

    func scheduler(for accountLogin: String) async throws(GHError) -> GHCommandScheduler {
        let service = GHCommandService(
            executableURL: GHFixtures.ghURL,
            identity: GHFixtures.identity,
            shell: .empty,
            workingDirectory: GHFixtures.workingDirectory,
            runner: runner
        )
        return GHCommandScheduler(
            accountLogin: accountLogin,
            service: service,
            auth: GHAuthService(service: service, tokenCache: tokenCache),
            clock: clock
        )
    }

    /// Scripts a full import of `owner-a/repo-a` (see ``GHFixtures``).
    func scriptImport(
        permission: String = "ADMIN",
        repoVariables: [(name: String, value: String)] = [(name: "FXV_FIXTURE_URL", value: "https://example.invalid/api")],
        repoSecretsFailure: String? = nil
    ) {
        let repo = "owner-a/repo-a"
        runner.enqueue(.success(GHFixtures.repoJSON(owner: "owner-a", name: "repo-a", permission: permission)), matching: GHArgv.isRepoView(repo))
        runner.enqueue(.success(GHFixtures.environments), matching: GHArgv.isEnvironmentList(repo))
        runner.enqueue(.success(GHFixtures.branchPolicies), matching: GHArgv.isBranchPolicyList(repo, environment: "production"))
        if let repoSecretsFailure {
            runner.enqueue(.failure(stderr: repoSecretsFailure), matching: GHArgv.isList("secret", repo: repo, environment: nil))
        } else {
            runner.enqueue(.success(GHFixtures.secrets(["FXV_FIXTURE_API_TOKEN", "1FXV_FIXTURE_BAD"])), matching: GHArgv.isList("secret", repo: repo, environment: nil)) // gitleaks:allow (secret names only, no values)
        }
        runner.enqueue(.success(GHFixtures.variables(repoVariables)), matching: GHArgv.isList("variable", repo: repo, environment: nil))
        runner.enqueue(.success(GHFixtures.secrets(["FXV_FIXTURE_DSN"])), matching: GHArgv.isList("secret", repo: repo, environment: "production"))
        runner.enqueue(
            .success(GHFixtures.variables([(name: "FXV_FIXTURE_PEM", value: "-----BEGIN FXV FIXTURE-----\\nAAAA\\n-----END FXV FIXTURE-----\\n")])),
            matching: GHArgv.isList("variable", repo: repo, environment: "production")
        )
        runner.enqueue(.success("[]"), matching: GHArgv.isList("secret", repo: repo, environment: "staging"))
        runner.enqueue(.success("[]"), matching: GHArgv.isList("variable", repo: repo, environment: "staging"))
    }
}

/// Runs `body` and returns the ``RepoCatalogError`` it throws, or nil.
func catalogError(_ body: () async throws -> Void) async -> RepoCatalogError? {
    do {
        try await body()
        return nil
    } catch let error as RepoCatalogError {
        return error
    } catch {
        Issue.record("Expected a RepoCatalogError, got \(error)")
        return nil
    }
}
