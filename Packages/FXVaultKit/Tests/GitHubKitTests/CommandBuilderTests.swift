import Foundation
import Testing
@testable import GitHubKit
import VaultCore

/// argv builders for every §8 operation: `--repo=`/`--env=` forms, no forbidden flag, no
/// `--clone`, names validated before argv exists.
@Suite("gh argv builders")
struct CommandBuilderTests {
    static let apiHeaders = [
        "api", "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2026-03-10",
    ]

    /// Every command any builder can produce (with an environment where applicable).
    static func allCommands() throws -> [GHCommand] {
        let repo = try TestValues.repo()
        let value = TestValues.secret("FXV_FIXTURE_VALUE")
        let flags = GitHubBranchPolicyFlagsModel(protectedBranches: false, customBranchPolicies: true)
        return [
            try GHLocator.versionCommand(),
            try GHAuthService.statusCommand(),
            try GHAuthService.tokenCommand(login: "user-a"),
            try GHOrgsCommands.list(),
            try GHReposCommands.list(owner: "owner-a"),
            try GHReposCommands.view(repo),
            try GHReposCommands.create(GHRepoCreateRequest(
                repo: repo,
                visibility: .private,
                description: "--body=not a flag",
                addReadme: true,
                gitignoreTemplate: "Swift",
                licenseTemplate: "mit"
            )),
            try GHTemplatesCommands.gitignoreList(),
            try GHTemplatesCommands.licenseList(),
            try GHSecretsCommands.list(repo: repo),
            try GHSecretsCommands.list(repo: repo, environment: "production"),
            try GHSecretsCommands.set(name: "api_token", repo: repo, environment: "production", value: value),
            try GHSecretsCommands.delete(name: "API_TOKEN", repo: repo, environment: "production"),
            try GHVariablesCommands.list(repo: repo, environment: "production"),
            try GHVariablesCommands.set(name: "API_URL", repo: repo, value: value, isUpdate: true),
            try GHVariablesCommands.delete(name: "API_URL", repo: repo),
            try GHEnvironmentsAPI.list(repo: repo),
            try GHEnvironmentsAPI.get(repo: repo, environment: "production"),
            try GHEnvironmentsAPI.listBranchPolicies(repo: repo, environment: "production"),
            try GHEnvironmentsAPI.upsert(repo: repo, environment: "production", branchPolicy: flags),
            try GHEnvironmentsAPI.addBranchPolicy(repo: repo, environment: "production", pattern: "release/*", type: .branch),
            try GHEnvironmentsAPI.deleteBranchPolicy(repo: repo, environment: "production", policyID: 42),
            try GHEnvironmentsAPI.delete(repo: repo, environment: "production"),
            try GHManifestAPI.get(repo: repo),
        ]
    }

    @Test func noCommandCarriesAForbiddenFlag() throws {
        let commands = try Self.allCommands()
        #expect(Set(commands.map(\.operation)) == Set(GHOperation.allCases))
        for command in commands {
            for argument in command.arguments {
                #expect(!GHArgumentPolicy.isForbidden(argument), "\(command.operation.rawValue): \(argument)")
            }
            #expect(!command.arguments.contains("--clone"))
            #expect(!command.arguments.contains { $0.hasPrefix("--body") })
            #expect(!command.arguments.contains { $0.hasPrefix("--env-file") })
        }
    }

    @Test func apiIsUsedOnlyForEnvironmentsAndBranchPolicies() throws {
        for command in try Self.allCommands() {
            #expect((command.arguments.first == "api") == command.operation.usesAPI)
            if command.operation.usesAPI {
                #expect(command.arguments.contains("-X"), "every gh api call has an explicit method")
            }
        }
    }

    @Test(arguments: [
        "--body", "--body=x", "-b", "-bvalue", "-f", "-fFILE", "--env-file", "--env-file=.env", "--no-store",
        "--verbose", "--show-token", "--cache", "--cache=1h", "--clone", "-F", "-Fkey=v", "--raw-field", "--field=a=b",
    ])
    func policyRejectsForbiddenFlags(argument: String) {
        #expect(GHArgumentPolicy.isForbidden(argument))
        #expect(throws: GHError.self) { try GHArgumentPolicy.validate(["secret", "set", "X", argument]) }
    }

    @Test(arguments: ["--repo=owner-a/repo-a", "--env=production", "-H", "-X", "-i", "--paginate", "--slurp", "--input", "-"])
    func policyAllowsTheFlagsFXVaultUses(argument: String) {
        #expect(!GHArgumentPolicy.isForbidden(argument))
    }

    @Test func secretCommands() throws {
        let repo = try TestValues.repo()
        #expect(try GHSecretsCommands.list(repo: repo).arguments
            == ["secret", "list", "--repo=owner-a/repo-a", "--json", "name,updatedAt"])
        #expect(try GHSecretsCommands.list(repo: repo, environment: "Producción").arguments
            == ["secret", "list", "--repo=owner-a/repo-a", "--env=Producción", "--json", "name,updatedAt"])
        let set = try GHSecretsCommands.set(name: "api_token", repo: repo, environment: "staging", value: TestValues.secret("v"))
        #expect(set.arguments == ["secret", "set", "API_TOKEN", "--repo=owner-a/repo-a", "--env=staging"])
        #expect(set.logTemplate == "secret set {n} --repo={o}/{r} --env={e}")
        #expect(set.writeCost == Limits.defaultWriteCost)
        #expect(set.operation.isIdempotent)
        #expect(try GHSecretsCommands.delete(name: "API_TOKEN", repo: repo).arguments
            == ["secret", "delete", "API_TOKEN", "--repo=owner-a/repo-a"])
    }

    @Test func variableCommands() throws {
        let repo = try TestValues.repo()
        #expect(try GHVariablesCommands.list(repo: repo).arguments
            == ["variable", "list", "--repo=owner-a/repo-a", "--json", "name,value,updatedAt,createdAt"])
        let update = try GHVariablesCommands.set(
            name: "API_URL", repo: repo, environment: "qa", value: TestValues.secret("v"), isUpdate: true
        )
        #expect(update.arguments == ["variable", "set", "API_URL", "--repo=owner-a/repo-a", "--env=qa"])
        #expect(update.writeCost == Limits.variableUpdateWriteCost)
        let create = try GHVariablesCommands.set(name: "API_URL", repo: repo, value: TestValues.secret("v"), isUpdate: false)
        #expect(create.writeCost == Limits.defaultWriteCost)
        #expect(try GHVariablesCommands.delete(name: "API_URL", repo: repo, environment: "qa").arguments
            == ["variable", "delete", "API_URL", "--repo=owner-a/repo-a", "--env=qa"])
    }

    /// 0.9's shared spaces wrote `FXVAULT_SPACE` (S4): 1.0 never writes it, keeps the name
    /// reserved, and drops it from listings so a 0.9 repository never shows it as a variable.
    @Test func theOldSpaceMarkerIsReservedAndNeverListed() throws {
        let repo = try TestValues.repo()
        #expect(throws: GHError.invalidInput(.invalidName(.reservedName))) {
            try GHVariablesCommands.set(name: "fxvault_space", repo: repo, value: TestValues.secret("v"), isUpdate: false)
        }
        #expect(throws: GHError.invalidInput(.invalidName(.reservedName))) {
            try GHVariablesCommands.delete(name: "FXVAULT_SPACE", repo: repo)
        }
        let listed = GHVariablesCommands.droppingSpaceMarker([
            GHVariableListingModel(name: "API_URL", value: TestValues.secret("https://example.com"), updatedAt: nil, createdAt: nil),
            GHVariableListingModel(name: "FXVAULT_SPACE", value: TestValues.secret("{\"v\":2}"), updatedAt: nil, createdAt: nil),
        ])
        #expect(listed.map(\.name) == ["API_URL"])
    }

    @Test func repoCommands() throws {
        let repo = try TestValues.repo()
        #expect(try GHReposCommands.list(owner: "owner-a").arguments == [
            "repo", "list", "owner-a", "--limit", "1000", "--json", GHRepoDTO.jsonFields,
        ])
        #expect(GHRepoDTO.jsonFields
            == "id,name,nameWithOwner,owner,isPrivate,visibility,isArchived,isFork,viewerPermission,viewerCanAdminister,defaultBranchRef,sshUrl,createdAt")
        #expect(try GHReposCommands.view(repo).arguments == ["repo", "view", "owner-a/repo-a", "--json", GHRepoDTO.jsonFields])
        let create = try GHReposCommands.create(GHRepoCreateRequest(
            repo: repo,
            visibility: .public,
            description: "My app",
            addReadme: true,
            gitignoreTemplate: "Swift",
            licenseTemplate: "mit"
        ))
        #expect(create.arguments == [
            "repo", "create", "owner-a/repo-a", "--public", "--description=My app", "--add-readme",
            "--gitignore=Swift", "--license=mit",
        ])
        #expect(!create.operation.isIdempotent, "repo create is never retried")
        let minimal = try GHReposCommands.create(GHRepoCreateRequest(repo: repo, visibility: .private))
        #expect(minimal.arguments == ["repo", "create", "owner-a/repo-a", "--private"])
    }

    @Test func authAndDiscoveryCommands() throws {
        #expect(try GHAuthService.statusCommand().arguments == ["auth", "status", "--hostname", "github.com", "--json", "hosts"])
        #expect(try GHAuthService.tokenCommand(login: "user-a").arguments
            == ["auth", "token", "--hostname", "github.com", "--user=user-a"])
        #expect(try GHOrgsCommands.list().arguments == ["org", "list", "--limit", "300"])
        #expect(try GHTemplatesCommands.gitignoreList().arguments == ["repo", "gitignore", "list"])
        #expect(try GHTemplatesCommands.licenseList().arguments == ["repo", "license", "list"])
        #expect(GHOperation.authToken.timeout == Timeouts.ghAuthToken)
        #expect(GHOperation.repoList.timeout == Timeouts.ghRepoList)
        #expect(GHOperation.secretSet.timeout == Timeouts.ghDefault)
        #expect(!GHOperation.authStatus.requiresToken && !GHOperation.authToken.requiresToken && !GHOperation.version.requiresToken)
    }

    @Test func environmentAPICommands() throws {
        let repo = try TestValues.repo()
        #expect(try GHEnvironmentsAPI.list(repo: repo).arguments
            == Self.apiHeaders + ["-X", "GET", "--paginate", "--slurp", "repos/owner-a/repo-a/environments?per_page=100"])
        #expect(try GHEnvironmentsAPI.get(repo: repo, environment: "Producción").arguments
            == Self.apiHeaders + ["-X", "GET", "-i", "repos/owner-a/repo-a/environments/Producci%C3%B3n"])
        #expect(try GHEnvironmentsAPI.listBranchPolicies(repo: repo, environment: "prod").arguments
            == Self.apiHeaders + [
                "-X", "GET", "--paginate", "--slurp",
                "repos/owner-a/repo-a/environments/prod/deployment-branch-policies?per_page=100",
            ])
        #expect(try GHEnvironmentsAPI.upsert(repo: repo, environment: "prod", branchPolicy: nil).arguments
            == Self.apiHeaders + ["-X", "PUT", "-i", "repos/owner-a/repo-a/environments/prod", "--input", "-"])
        #expect(try GHEnvironmentsAPI.addBranchPolicy(repo: repo, environment: "prod", pattern: "v*", type: .tag).arguments
            == Self.apiHeaders + [
                "-X", "POST", "-i", "repos/owner-a/repo-a/environments/prod/deployment-branch-policies", "--input", "-",
            ])
        #expect(try GHEnvironmentsAPI.deleteBranchPolicy(repo: repo, environment: "prod", policyID: 361_471).arguments
            == Self.apiHeaders + ["-X", "DELETE", "-i", "repos/owner-a/repo-a/environments/prod/deployment-branch-policies/361471"])
        #expect(try GHEnvironmentsAPI.delete(repo: repo, environment: "a b").arguments
            == Self.apiHeaders + ["-X", "DELETE", "-i", "repos/owner-a/repo-a/environments/a%20b"])
    }

    @Test func environmentBodiesGoOnStdin() throws {
        let repo = try TestValues.repo()
        func body(_ command: GHCommand) -> String {
            command.stdinValue?.utf8String() ?? ""
        }
        #expect(body(try GHEnvironmentsAPI.upsert(repo: repo, environment: "prod", branchPolicy: nil))
            == #"{"deployment_branch_policy":null}"#)
        #expect(body(try GHEnvironmentsAPI.upsert(
            repo: repo,
            environment: "prod",
            branchPolicy: GitHubBranchPolicyFlagsModel(protectedBranches: true, customBranchPolicies: false)
        )) == #"{"deployment_branch_policy":{"custom_branch_policies":false,"protected_branches":true}}"#)
        #expect(body(try GHEnvironmentsAPI.upsert(
            repo: repo,
            environment: "prod",
            branchPolicy: DeploymentBranchPolicyModel.custom([]).gitHubFlags
        )) == #"{"deployment_branch_policy":{"custom_branch_policies":true,"protected_branches":false}}"#)
        #expect(body(try GHEnvironmentsAPI.addBranchPolicy(repo: repo, environment: "prod", pattern: "release/*", type: .branch))
            == #"{"name":"release/*","type":"branch"}"#)
    }

    @Test(arguments: [".", "..", "%2E%2E", "a/..", "a/b", "", " prod", "pro\u{202E}d", "zero\u{200B}width"])
    func invalidEnvironmentNamesNeverReachArgv(name: String) throws {
        let repo = try TestValues.repo()
        #expect(throws: GHError.self) { try GHSecretsCommands.list(repo: repo, environment: name) }
        #expect(throws: GHError.self) { try GHEnvironmentsAPI.delete(repo: repo, environment: name) }
        #expect(throws: GHError.self) { try GHEnvironmentsAPI.get(repo: repo, environment: name) }
    }

    @Test(arguments: ["1ABC", "GITHUB_TOKEN", "A-B", "", "--body", "-b", "NAME WITH SPACE", "straße"])
    func invalidItemNamesNeverReachArgv(name: String) throws {
        let repo = try TestValues.repo()
        #expect(throws: GHError.self) {
            try GHSecretsCommands.set(name: name, repo: repo, value: TestValues.secret("v"))
        }
        #expect(throws: GHError.self) { try GHVariablesCommands.delete(name: name, repo: repo) }
    }

    /// Enterprise Managed User accounts (`handle_shortcode`) own personal repositories: every
    /// argv builder accepts them (v0.3.1; synthetic logins).
    @Test func managedUserOwnersAndAccounts() throws {
        let repo = try GHRepoRef(owner: "user1_acme", name: "some-repo")
        #expect(repo.repoFlag == "--repo=user1_acme/some-repo")
        #expect(repo.foldKey == "user1_acme/some-repo")
        #expect(try GHRepoRef(fullName: "user1-e_acme/some-repo").owner == "user1-e_acme")
        #expect(try GHRepoRef(repositoryURL: "https://github.com/user1_acme/new-repo\n").fullName == "user1_acme/new-repo")
        #expect(try GHReposCommands.list(owner: "user1_acme").arguments.prefix(3) == ["repo", "list", "user1_acme"])
        #expect(try GHReposCommands.view(repo).arguments.prefix(3) == ["repo", "view", "user1_acme/some-repo"])
        #expect(try GHAuthService.tokenCommand(login: "user1-e_acme").arguments
            == ["auth", "token", "--hostname", "github.com", "--user=user1-e_acme"])
        #expect(try GHSecretsCommands.list(repo: repo).arguments.contains("--repo=user1_acme/some-repo"))
        #expect(try GHEnvironmentsAPI.list(repo: repo).arguments.last == "repos/user1_acme/some-repo/environments?per_page=100")
        #expect(ScopeChecker.fixCommands(login: "user1-e_acme", previousActiveLogin: "user1_acme") == [
            "gh auth switch -h github.com -u user1-e_acme",
            "gh auth refresh -h github.com -s repo,read:org",
            "gh auth switch -h github.com -u user1_acme",
        ])
        #expect(throws: GHError.self) { try GHRepoRef(owner: "_user1", name: "repo") }
    }

    @Test func invalidOwnersAndRepositoriesAreRejected() {
        #expect(throws: GHError.self) { try GHRepoRef(owner: "-oProxyCommand", name: "repo") }
        #expect(throws: GHError.self) { try GHRepoRef(owner: "owner", name: "..") }
        #expect(throws: GHError.self) { try GHRepoRef(owner: "owner", name: "repo.git") }
        #expect(throws: GHError.self) { try GHRepoRef(fullName: "owner/repo/extra") }
        #expect(throws: GHError.self) { try GHReposCommands.list(owner: "--limit") }
        #expect(throws: GHError.self) { try GHAuthService.tokenCommand(login: "-x") }
    }

    @Test func valuesAreValidatedBeforeTheCommandExists() throws {
        let repo = try TestValues.repo()
        #expect(throws: GHError.invalidInput(.emptyValue)) {
            try GHSecretsCommands.set(name: "A", repo: repo, value: SecretBytes(count: 0))
        }
        #expect(throws: GHError.invalidInput(.valueTooLarge(limit: Limits.maxValueBytes))) {
            try GHVariablesCommands.set(
                name: "A", repo: repo, value: SecretBytes(count: Limits.maxValueBytes + 1), isUpdate: false
            )
        }
        #expect(throws: GHError.self) {
            try GHReposCommands.create(GHRepoCreateRequest(repo: repo, visibility: .private, description: "bad\u{0}"))
        }
    }

    @Test func commandsDoNotPrintTheirValues() throws {
        let command = try GHSecretsCommands.set(
            name: "A", repo: try TestValues.repo(), value: TestValues.secret("FXV_FIXTURE_PLAINTEXT")
        )
        let text = "\(command) \(String(reflecting: command)) \(String(describing: Mirror(reflecting: command).children.map(\.value)))"
        #expect(!text.contains("FXV_FIXTURE_PLAINTEXT"))
    }
}

@Suite("Stdin-only values (property)")
struct StdinPropertyTests {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=+/ :.\"'$`\\\n\t{}")

    /// Random values: never in argv, always on stdin byte for byte, payload wiped afterwards.
    @Test func randomValuesNeverAppearInArgv() async throws {
        var generator = SystemRandomNumberGenerator()
        let repo = try TestValues.repo()
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: [], with: .success())
        let service = TestValues.service(runner)
        let iterations = 200
        for iteration in 0..<iterations {
            let length = Int.random(in: 12...256, using: &generator)
            let text = "FXV" + String((0..<length).map { _ in Self.alphabet.randomElement(using: &generator) ?? "x" })
            let value = TestValues.secret(text)
            let environment: String? = iteration.isMultiple(of: 2) ? "production" : nil
            let command = iteration.isMultiple(of: 3)
                ? try GHVariablesCommands.set(name: "VAR_\(iteration)", repo: repo, environment: environment, value: value, isUpdate: false)
                : try GHSecretsCommands.set(name: "SECRET_\(iteration)", repo: repo, environment: environment, value: value)
            _ = try await service.execute(command, token: TestValues.secret(TestValues.token))
            command.wipe()
            let call = try #require(runner.invocations.last)
            #expect(!call.arguments.contains { $0.contains(text) })
            #expect(!call.environment.values.contains { $0.contains(text) })
            #expect(call.stdin == Data(text.utf8))
            #expect(command.stdinValue?.isWiped == true)
            #expect(!value.isWiped, "the caller's buffer belongs to the caller")
        }
    }
}

@Suite("GitHubPath")
struct GitHubPathTests {
    @Test func percentEncodesWithTheUnreservedSet() {
        #expect(GitHubPath.percentEncode("a/b c") == "a%2Fb%20c")
        #expect(GitHubPath.percentEncode("a–b") == "a%E2%80%93b")
        #expect(GitHubPath.percentEncode("Producción") == "Producci%C3%B3n")
        #expect(GitHubPath.percentEncode("a?b#c%d&e=f+g") == "a%3Fb%23c%25d%26e%3Df%2Bg")
        #expect(GitHubPath.percentEncode("A-Z.a_z~0") == "A-Z.a_z~0")
    }

    @Test(arguments: [".", "..", "%2E%2E", ".%2e", "%252E%252E", "a/..", "a/b", "", "%2F", "%00", "a\u{0}b", "a\\b"])
    func rejectsUnsafeSegments(segment: String) {
        #expect(throws: GHError.self) { try GitHubPath.encodeValidated(segment) }
    }

    @Test func buildsEnvironmentPaths() throws {
        let repo = try TestValues.repo()
        #expect(try GitHubPath.environments(repo).rendered == "repos/owner-a/repo-a/environments?per_page=100")
        #expect(try GitHubPath.environment(repo, name: "staging – eu").rendered
            == "repos/owner-a/repo-a/environments/staging%20%E2%80%93%20eu")
        #expect(try GitHubPath.branchPolicy(repo, environment: "prod", policyID: 7).rendered
            == "repos/owner-a/repo-a/environments/prod/deployment-branch-policies/7")
        #expect(throws: GHError.self) { try GitHubPath.environment(repo, name: "..") }
    }
}
