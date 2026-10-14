import Foundation
import Testing
@testable import GitHubKit
import VaultCore

/// Decoding of sanitized native `--json`, plain-text and `gh api` fixtures (tasks/todo.md M2).
@Suite("Output decoding")
struct DecodingTests {
    private func output(_ operation: GHOperation, fixture: String) throws -> GHCommandOutput {
        var data = try Fixture.data(fixture)
        return GHCommandOutput(operation: operation, stdout: SecretBytes(wipingSource: &data))
    }

    private func apiOutput(_ operation: GHOperation, fixture: String) throws -> GHCommandOutput {
        GHCommandOutput(
            operation: operation,
            stdout: SecretBytes(count: 0),
            response: try APIResponseParser.parse(try Fixture.data(fixture))
        )
    }

    // MARK: - A3

    @Test func authStatusSingleAccount() throws {
        let accounts = try GHAuthService.decodeAccounts(try output(.authStatus, fixture: "gh/auth-status.json"))
        #expect(accounts.count == 1)
        let account = try #require(accounts.first)
        #expect(account.login == "user-a")
        #expect(account.isActive)
        #expect(account.state == .ok)
        #expect(account.scopeList == ["gist", "read:org", "repo"], "split on commas and trimmed")
        #expect(account.scopes == .ok)
    }

    @Test func authStatusMultipleAccounts() throws {
        let accounts = try GHAuthService.decodeAccounts(try output(.authStatus, fixture: "gh/auth-status-multi.json"))
        #expect(accounts.map(\.login) == ["user-a", "user-b", "user-c", "user-d", "user-e", "user-f"], "github.com only")
        let byLogin = Dictionary(uniqueKeysWithValues: accounts.map { ($0.login, $0) })
        #expect(byLogin["user-b"]?.scopes == .unknown, "absent scopes key (omitempty) means unknown")
        #expect(byLogin["user-b"]?.scopeList == nil)
        #expect(byLogin["user-c"]?.scopes == .missing(["repo", "read:org"]))
        #expect(byLogin["user-d"]?.state == .offline, "a DNS error is offline, not re-login")
        #expect(byLogin["user-e"]?.state == .reloginRequired)
        #expect(byLogin["user-f"]?.state == .offline, "state timeout")
    }

    @Test func authStatusWithNoAccounts() throws {
        #expect(try GHAuthService.decodeAccounts(try output(.authStatus, fixture: "gh/auth-status-empty.json")).isEmpty)
    }

    @Test func scopeChecks() {
        #expect(ScopeChecker.check("repo, admin:org") == .ok)
        #expect(ScopeChecker.check("repo,write:org") == .ok)
        #expect(ScopeChecker.check("read:org") == .missing(["repo"]))
        #expect(ScopeChecker.check("") == .unknown)
        #expect(ScopeChecker.check(nil) == .unknown)
        #expect(ScopeChecker.parse("gist, read:org, repo") == ["gist", "read:org", "repo"])
        #expect(ScopeChecker.fixCommands(login: "user-b", previousActiveLogin: "user-a") == [
            "gh auth switch -h github.com -u user-b",
            "gh auth refresh -h github.com -s repo,read:org",
            "gh auth switch -h github.com -u user-a",
        ])
        #expect(ScopeChecker.fixCommands(login: "user-a", previousActiveLogin: "USER-A").count == 2)
    }

    @Test func tokenOutputIsTrimmed() throws {
        let token = try GHAuthService.decodeToken(GHCommandOutput(
            operation: .authToken,
            stdout: TestValues.secret(" \(TestValues.token)\n")
        ))
        #expect(token.utf8String() == TestValues.token)
        #expect(throws: GHError.notAuthenticated) {
            try GHAuthService.decodeToken(GHCommandOutput(operation: .authToken, stdout: TestValues.secret("\n")))
        }
    }

    // MARK: - B1, B2, C1

    @Test func repoList() throws {
        let out = try output(.repoList, fixture: "gh/repo-list.json")
        let repos = try GHReposCommands.decodeList(out)
        #expect(out.stdout.isWiped, "stdout is wiped after decoding")
        #expect(repos.count == 3)
        let first = repos[0]
        #expect(first.repoRef == (try TestValues.repo()))
        #expect(first.permission == .admin)
        #expect(first.defaultBranch == "main")
        #expect(first.repoVisibility == .private)
        let second = repos[1]
        #expect(second.defaultBranch == nil, "empty repository")
        #expect(second.permission == .write)
        #expect(repos[2].repoRef == nil, "invalid names are skipped")
        #expect(repos[2].permission == nil)
        #expect(repos[2].repoVisibility == .internal)

        let importedAt = Date(timeIntervalSince1970: 0)
        let model = try #require(first.makeRepoModel(accountLogin: "user-a", ownerType: .organization, importedAt: importedAt))
        #expect(model.fullName == "owner-a/repo-a")
        #expect(model.githubID == "R_kgDOAAAAAA")
        #expect(model.hasAdmin && model.hasPush)
        #expect(model.ownerType == .organization)
        #expect(model.origin == .imported)
        #expect(model.createdAtGitHub == GHJSONDecoding.parseDate("2026-01-02T03:04:05Z"))
        let writer = try #require(second.makeRepoModel(accountLogin: "user-a", ownerType: .user, importedAt: importedAt))
        #expect(!writer.hasAdmin && writer.hasPush)
        #expect(repos[2].makeRepoModel(accountLogin: "user-a", ownerType: .user, importedAt: importedAt) == nil)
    }

    @Test func repoView() throws {
        let repo = try GHReposCommands.decodeView(try output(.repoView, fixture: "gh/repo-view.json"))
        #expect(repo.nameWithOwner == "owner-b/repo-c")
        #expect(repo.permission == .read)
        #expect(repo.defaultBranch == "trunk")
    }

    @Test func repoCreatePrintsTheNormalizedName() throws {
        let ref = try GHReposCommands.decodeCreated(try output(.repoCreate, fixture: "gh/repo-create.txt"))
        #expect(ref.fullName == "owner-a/new-repo")
        #expect(throws: GHError.malformedOutput) {
            try GHRepoRef(repositoryURL: "https://evil.example/owner-a/new-repo")
        }
        #expect(throws: GHError.malformedOutput) {
            try GHRepoRef(repositoryURL: "https://github.com/owner-a")
        }
    }

    @Test func malformedJSONIsReported() {
        #expect(throws: GHError.malformedOutput) {
            try GHReposCommands.decodeList(GHCommandOutput(operation: .repoList, stdout: TestValues.secret("[{")))
        }
        #expect(throws: GHError.malformedOutput) {
            try GHSecretsCommands.decodeList(GHCommandOutput(operation: .secretList, stdout: TestValues.secret("[{\"x\":1}]")))
        }
    }

    // MARK: - B6–B9

    @Test func secretList() throws {
        let secrets = try GHSecretsCommands.decodeList(try output(.secretList, fixture: "gh/secret-list.json"))
        #expect(secrets.map(\.name) == ["FXV_FIXTURE_API_TOKEN", "FXV_FIXTURE_DSN"])
        #expect(secrets[0].updatedAt == GHJSONDecoding.parseDate("2026-10-01T10:00:00Z"))
        #expect(secrets[1].updatedAt != nil, "fractional seconds decode")
        #expect(try GHSecretsCommands.decodeList(try output(.secretList, fixture: "gh/secret-list-empty.json")).isEmpty)
    }

    @Test func variableListValuesBecomeSecretBytes() throws {
        let out = try output(.variableList, fixture: "gh/variable-list.json")
        let variables = try GHVariablesCommands.decodeList(out)
        #expect(out.stdout.isWiped)
        #expect(variables.map(\.name) == ["FXV_FIXTURE_URL", "FXV_FIXTURE_PEM", "FXV_FIXTURE_UNICODE"])
        #expect(variables[0].value.utf8String() == "https://example.invalid/api")
        #expect(variables[1].value.utf8String()?.hasSuffix("-----\n") == true, "listed values keep trailing newlines (D32)")
        #expect(variables[2].value.utf8String() == "Producción – ✓")
        #expect(!"\(variables[0])".contains("example.invalid"))
        variables.forEach { $0.wipe() }
        #expect(variables.allSatisfy { $0.value.isWiped })
    }

    // MARK: - A5, B10

    @Test func orgListSkipsInvalidAndDuplicateLogins() throws {
        #expect(GHOrgsCommands.parseList(try Fixture.string("gh/org-list.txt")) == ["owner-a", "org-b"])
    }

    @Test func templateLists() throws {
        #expect(GHTemplatesCommands.parseGitignoreList(try Fixture.string("gh/gitignore-list.txt"))
            == ["Actionscript", "Ada", "C++", "Objective-C", "Swift", "VisualStudio"])
        let licenses = GHTemplatesCommands.parseLicenseList(try Fixture.string("gh/license-list.txt"))
        #expect(licenses.map(\.key) == ["agpl-3.0", "apache-2.0", "bsd-3-clause", "mit", "unlicense"])
        #expect(licenses[3] == GHLicenseTemplateModel(key: "mit", spdxID: "MIT", name: "MIT License"))
        #expect(GHTemplatesCommands.parseLicenseList("mit   MIT   MIT License\n").first?.key == "mit")
    }

    // MARK: - gh api

    @Test func environmentsAcrossTwoSlurpedPages() throws {
        let environments = try GHEnvironmentsAPI.decodeList(try output(.environmentList, fixture: "api/environments-paginated.json"))
        #expect(environments.map(\.name) == ["production", "staging", "Producción"])
        #expect(environments.map(\.branchPolicyKind) == [.custom, .all, .protected])
        let production = environments[0]
        #expect(production.id == 101)
        #expect(production.protectionRules.count == 2)
        #expect(production.foreignRules.count == 1, "branch_policy rules are managed, not foreign")
        let foreign = try #require(production.foreignRulesJSON)
        #expect(foreign.contains("required_reviewers"))
        #expect(!foreign.contains("branch_policy"))
        #expect(environments[1].foreignRulesJSON == nil)
        #expect(environments[2].foreignRulesJSON?.contains("wait_timer") == true)
        #expect(environments.allSatisfy { $0.hasValidName })
        #expect(try GHEnvironmentsAPI.decodeList(try output(.environmentList, fixture: "api/environments-empty.json")).isEmpty)
    }

    @Test func branchPoliciesAcrossTwoSlurpedPages() throws {
        let policies = try GHEnvironmentsAPI.decodeBranchPolicies(
            try output(.branchPolicyList, fixture: "api/branch-policies-paginated.json")
        )
        #expect(policies == [
            GHBranchPolicyDTO(id: 361_471, name: "release/*", type: .branch),
            GHBranchPolicyDTO(id: 361_472, name: "v*", type: .tag),
            GHBranchPolicyDTO(id: 361_473, name: "main", type: .branch),
        ])
    }

    @Test func includeHeadResponses() throws {
        let ok = try APIResponseParser.parse(try Fixture.data("api/environment-get-200.txt"))
        #expect(ok.status == 200)
        #expect(ok.isSuccess)
        #expect(ok.headers["content-type"] == "application/json; charset=utf-8")
        #expect(ok.headers["x-github-request-id"] == nil, "only kept headers survive")
        let environment = try GHEnvironmentsAPI.decodeEnvironment(try apiOutput(.environmentGet, fixture: "api/environment-get-200.txt"))
        #expect(environment.name == "staging")
        #expect(environment.branchPolicyKind == .all)

        let missing = try APIResponseParser.parse(try Fixture.data("api/environment-get-404.txt"))
        #expect(missing.status == 404)
        #expect(!missing.isSuccess)
        #expect(APIResponseParser.statusIfPresent(in: try Fixture.data("api/environment-get-404.txt")) == 404)

        let deleted = try APIResponseParser.parse(try Fixture.data("api/delete-204.txt"))
        #expect(deleted.status == 204)
        #expect(deleted.body.isEmpty)

        let added = try GHEnvironmentsAPI.decodeAddedBranchPolicy(try apiOutput(.branchPolicyAdd, fixture: "api/branch-policy-add-200.txt"))
        #expect(added == GHBranchPolicyDTO(id: 361_474, name: "release/*", type: .branch))
        #expect(try GHEnvironmentsAPI.decodeAddedBranchPolicy(try apiOutput(.branchPolicyAdd, fixture: "api/branch-policy-add-303.txt")) == nil)
    }

    @Test func parserAcceptsLFOnlyAndRejectsGarbage() throws {
        let response = try APIResponseParser.parse(Data("HTTP/1.1 201 Created\nLocation: https://x\n\n{}".utf8))
        #expect(response.status == 201)
        #expect(response.headers["location"] == "https://x")
        #expect(response.body == Data("{}".utf8))
        #expect(throws: GHError.malformedOutput) { try APIResponseParser.parse(Data("not http".utf8)) }
        #expect(APIResponseParser.statusCode(from: "HTTP/2.0 2000 OK") == nil)
    }
}

@Suite("GHStderrClassifier")
struct GHStderrClassifierTests {
    struct Case: Decodable, CustomTestStringConvertible {
        let name: String
        let operation: String
        let exitCode: Int32
        let stderr: String
        let expected: String
        let responseStatus: Int?
        let didTimeOut: Bool?
        let samlURL: String?
        let scopes: [String]?
        let synthetic: Bool

        var testDescription: String {
            name
        }
    }

    static func cases() throws -> [Case] {
        try JSONDecoder().decode([Case].self, from: try Fixture.data("gh/stderr-cases.json"))
    }

    @Test func tableOfRealisticSamples() throws {
        let cases = try Self.cases()
        #expect(cases.count >= 40)
        for sample in cases {
            let operation = try #require(GHOperation(rawValue: sample.operation), "\(sample.name)")
            let error = GHStderrClassifier.classify(GHFailureContext(
                operation: operation,
                exitCode: sample.exitCode,
                stderr: sample.stderr,
                responseStatus: sample.responseStatus,
                didTimeOut: sample.didTimeOut ?? false
            ))
            #expect(error.logCode == sample.expected, "\(sample.name)")
            if let expectedURL = sample.samlURL {
                guard case .samlRequired(let url) = error else {
                    Issue.record("\(sample.name): expected samlRequired")
                    continue
                }
                #expect(url?.absoluteString ?? "" == expectedURL, "\(sample.name)")
            }
            if let scopes = sample.scopes {
                #expect(error == .missingScopes(scopes), "\(sample.name)")
            }
        }
    }

    @Test func the401FixtureFromThePlanIsTokenRevoked() {
        let error = GHStderrClassifier.classify(GHFailureContext(
            operation: .secretList,
            exitCode: 1,
            stderr: "HTTP 401: Bad credentials (https://api.github.com/user)\nTry authenticating with:  gh auth login -h github.com"
        ))
        #expect(error == .tokenRevoked)
    }

    @Test func validationCarriesTheFirstLine() {
        let error = GHStderrClassifier.classify(GHFailureContext(
            operation: .repoCreate,
            exitCode: 1,
            stderr: "\nGraphQL: Name already exists on this account (createRepository)\nmore\n"
        ))
        #expect(error == .validation("GraphQL: Name already exists on this account (createRepository)"))
    }

    @Test func statusExtraction() {
        #expect(GHStderrClassifier.nativeStatus(in: "failed to delete secret X: HTTP 404: Not Found (url)") == 404)
        #expect(GHStderrClassifier.nativeStatus(in: "HTTP 4040: nope") == nil)
        #expect(GHStderrClassifier.apiStatus(in: "gh: Not Found (HTTP 404)") == 404)
        #expect(GHStderrClassifier.apiStatus(in: "gh: HTTP 303") == 303)
        #expect(GHStderrClassifier.apiStatus(in: "gh: Validation Failed (HTTP 422)\nmore") == 422)
        #expect(GHStderrClassifier.apiStatus(in: "gh: Variable already exists (name)") == nil)
    }
}

@Suite("StderrRedactor")
struct StderrRedactorTests {
    @Test func masksBothTokenPatterns() {
        let classic = "ghp_" + String(repeating: "A1b2", count: 9)
        let fineGrained = "github_pat_" + String(repeating: "Ab_9", count: 15)
        let text = "token \(classic) and \(fineGrained) and gho_short and ghx_\(String(repeating: "a", count: 30))"
        let redacted = StderrRedactor.redactTokenPatterns(in: text)
        #expect(!redacted.contains(classic))
        #expect(!redacted.contains(fineGrained))
        #expect(redacted.contains("gho_short"), "shorter than 20 characters is not a token")
        #expect(redacted.contains("ghx_"), "x is not a token prefix")
        #expect(redacted.components(separatedBy: GHConstants.redactionPlaceholder).count == 3)
    }

    @Test(arguments: ["gho_", "ghu_", "ghs_", "ghr_", "ghp_"])
    func everyClassicPrefix(prefix: String) {
        let token = prefix + String(repeating: "Z", count: StderrRedactor.minimumTokenBodyLength)
        #expect(StderrRedactor.redactTokenPatterns(in: "x\(token)y") == "x\(GHConstants.redactionPlaceholder)")
    }

    @Test func masksTheOperationsPlaintext() {
        let value = TestValues.secret("FXV_FIXTURE_VALUE\n")
        let redacted = StderrRedactor.redact(
            "failed: FXV_FIXTURE_VALUE was rejected; token \(TestValues.token)",
            secrets: [value, TestValues.secret(TestValues.token)]
        )
        #expect(!redacted.contains("FXV_FIXTURE_VALUE"))
        #expect(!redacted.contains(TestValues.token))
        #expect(redacted.contains(GHConstants.redactionPlaceholder))
    }
}
