import Foundation
import Testing
@testable import GitHubKit
import VaultCore

/// Organization writes (1.0, tasks/todo.md B6): C10–C13 always carry the visibility, `selected`
/// always carries its complete repository list, and B14/B15 read that list back.
@Suite("Organization writes")
struct OrgWriteTests {
    private func output(_ operation: GHOperation, _ json: String) -> GHCommandOutput {
        var data = Data(json.utf8)
        return GHCommandOutput(operation: operation, stdout: SecretBytes(wipingSource: &data))
    }

    private func selected(_ names: String...) throws -> GHOrgRepositoryAccess {
        .selected(try GHSelectedRepositories(names))
    }

    @Test func secretSetSendsEachVisibility() throws {
        let value = TestValues.secret("v")
        let all = try GHSecretsCommands.set(name: "npm_token", organization: "example-org", access: .all, value: value)
        #expect(all.arguments == ["secret", "set", "NPM_TOKEN", "--org=example-org", "--visibility=all"])
        #expect(all.logTemplate == "secret set {n} --org={o} --visibility=all")
        #expect(all.operation == .orgSecretSet)
        let privateOnly = try GHSecretsCommands.set(name: "NPM_TOKEN", organization: "example-org", access: .private, value: value)
        #expect(privateOnly.arguments == ["secret", "set", "NPM_TOKEN", "--org=example-org", "--visibility=private"])
        let some = try GHSecretsCommands.set(
            name: "NPM_TOKEN", organization: "example-org", access: try selected("api", "web.app", "Infra_2"), value: value
        )
        #expect(some.arguments == [
            "secret", "set", "NPM_TOKEN", "--org=example-org", "--visibility=selected", "--repos=api,web.app,Infra_2",
        ])
        #expect(some.logTemplate == "secret set {n} --org={o} --visibility=selected --repos={repos}")
        #expect(some.writeCost == Limits.defaultWriteCost)
    }

    @Test func variableSetSendsEachVisibilityAndItsUpdateCost() throws {
        let value = TestValues.secret("eu-west")
        let all = try GHVariablesCommands.set(name: "REGION", organization: "example-org", access: .all, value: value, isUpdate: false)
        #expect(all.arguments == ["variable", "set", "REGION", "--org=example-org", "--visibility=all"])
        #expect(all.operation == .orgVariableSet)
        #expect(all.writeCost == Limits.defaultWriteCost)
        let privateOnly = try GHVariablesCommands.set(
            name: "REGION", organization: "example-org", access: .private, value: value, isUpdate: true
        )
        #expect(privateOnly.arguments == ["variable", "set", "REGION", "--org=example-org", "--visibility=private"])
        #expect(privateOnly.writeCost == Limits.variableUpdateWriteCost)
        let some = try GHVariablesCommands.set(
            name: "REGION", organization: "example-org", access: try selected("api"), value: value, isUpdate: false
        )
        #expect(some.arguments == ["variable", "set", "REGION", "--org=example-org", "--visibility=selected", "--repos=api"])
        #expect(some.logTemplate == "variable set {n} --org={o} --visibility=selected --repos={repos}")
    }

    @Test func deletesUseTheOrgFlag() throws {
        let secret = try GHSecretsCommands.delete(name: "npm_token", organization: "example-org")
        #expect(secret.arguments == ["secret", "delete", "NPM_TOKEN", "--org=example-org"])
        #expect(secret.logTemplate == "secret delete {n} --org={o}")
        #expect(secret.operation == .orgSecretDelete)
        let variable = try GHVariablesCommands.delete(name: "REGION", organization: "example-org")
        #expect(variable.arguments == ["variable", "delete", "REGION", "--org=example-org"])
        #expect(variable.logTemplate == "variable delete {n} --org={o}")
        #expect(variable.operation == .orgVariableDelete)
    }

    @Test func theValueTravelsOnStdinAndNeverInArgvOrTheLog() async throws {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: [], with: .success())
        let service = TestValues.service(runner)
        let text = "FXV_ORG_FIXTURE_VALUE"
        let access = try selected("api", "web")
        let commands = [
            try GHSecretsCommands.set(name: "A", organization: "example-org", access: access, value: TestValues.secret(text)),
            try GHVariablesCommands.set(name: "B", organization: "example-org", access: access, value: TestValues.secret(text), isUpdate: false),
        ]
        for command in commands {
            _ = try await service.execute(command, token: TestValues.secret(TestValues.token))
            command.wipe()
            let call = try #require(runner.invocations.last)
            #expect(call.stdin == Data(text.utf8))
            #expect(!call.arguments.contains { $0.contains(text) })
            #expect(!command.logTemplate.contains(text))
            #expect(!command.logTemplate.contains("api") && !command.logTemplate.contains("web"), "names stay out of the log")
        }
    }

    @Test func selectedNeedsTheCompleteListOfValidNames() {
        #expect(throws: GHError.invalidInput(.invalidName(.empty))) { try GHSelectedRepositories([]) }
        #expect(throws: GHError.invalidInput(.duplicateName)) { try GHSelectedRepositories(["api", "API"]) }
        for name in ["", "..", "repo.git", "a,b", "a/b", "a b", "re\u{200B}po"] {
            #expect(throws: GHError.self, "\(name)") { try GHSelectedRepositories(["api", name]) }
        }
    }

    @Test func invalidOrganizationsAndNamesNeverReachArgv() throws {
        let value = TestValues.secret("v")
        for organization in ["-example", "example/org", "", "a b", ".."] {
            #expect(throws: GHError.self) { try GHSecretsCommands.set(name: "A", organization: organization, access: .all, value: value) }
            #expect(throws: GHError.self) { try GHVariablesCommands.delete(name: "A", organization: organization) }
            #expect(throws: GHError.self) { try GHSecretsCommands.selectedRepositories(name: "A", organization: organization) }
        }
        for name in ["1ABC", "GITHUB_TOKEN", "A-B", "", "--body", "FXVAULT_SPACE"] {
            #expect(throws: GHError.self) { try GHSecretsCommands.delete(name: name, organization: "example-org") }
            #expect(throws: GHError.self) {
                try GHVariablesCommands.set(name: name, organization: "example-org", access: .private, value: value, isUpdate: false)
            }
            #expect(throws: GHError.self) { try GHVariablesCommands.selectedRepositories(name: name, organization: "example-org") }
        }
        #expect(throws: GHError.invalidInput(.emptyValue)) {
            try GHSecretsCommands.set(name: "A", organization: "example-org", access: .all, value: SecretBytes(count: 0))
        }
    }

    @Test func selectedRepositoriesAreReadWithAPaginatedAPICall() throws {
        let secret = try GHSecretsCommands.selectedRepositories(name: "stripe_key", organization: "example-org")
        #expect(secret.arguments == CommandBuilderTests.apiHeaders + [
            "-X", "GET", "--paginate", "--slurp", "orgs/example-org/actions/secrets/STRIPE_KEY/repositories?per_page=100",
        ])
        #expect(secret.logTemplate == "api GET orgs/{o}/actions/secrets/{n}/repositories --paginate --slurp")
        #expect(secret.operation == .orgSecretRepositories)
        let variable = try GHVariablesCommands.selectedRepositories(name: "REGION", organization: "example-org")
        #expect(variable.arguments.last == "orgs/example-org/actions/variables/REGION/repositories?per_page=100")
        #expect(variable.operation == .orgVariableRepositories)
    }

    @Test func selectedRepositoriesDecodeEveryPage() throws {
        let names = try GHSecretsCommands.decodeSelectedRepositories(output(.orgSecretRepositories, """
        [{"total_count":3,"repositories":[{"id":1,"name":"api","full_name":"example-org/api","private":true},
                                          {"id":2,"name":"web.app","full_name":"example-org/web.app","private":false}]},
         {"total_count":3,"repositories":[{"id":3,"name":"Infra_2","full_name":"example-org/Infra_2","private":true}]}]
        """))
        #expect(names == ["api", "web.app", "Infra_2"])
        #expect(try GHSecretsCommands.decodeSelectedRepositories(output(
            .orgVariableRepositories, #"[{"total_count":0,"repositories":[]}]"#
        )).isEmpty)
    }

    @Test func aPartialOrInvalidRepositoryListIsMalformed() {
        let cases = [
            #"[{"total_count":2,"repositories":[{"name":"api"}]}]"#,
            #"[{"total_count":1,"repositories":[{"name":"../x"}]}]"#,
            #"[]"#,
            #"{"total_count":0,"repositories":[]}"#,
        ]
        for json in cases {
            #expect(throws: GHError.malformedOutput, "\(json)") {
                try GHSecretsCommands.decodeSelectedRepositories(output(.orgSecretRepositories, json))
            }
        }
    }

    @Test func operationsAreRegisteredAsWritesAndAPIReads() {
        for operation in [GHOperation.orgSecretSet, .orgSecretDelete, .orgVariableSet, .orgVariableDelete] {
            #expect(operation.isWrite && operation.isIdempotent && operation.requiresToken && !operation.usesAPI)
        }
        for operation in [GHOperation.orgSecretRepositories, .orgVariableRepositories] {
            #expect(!operation.isWrite && operation.usesAPI && !operation.includesResponseHead)
        }
        #expect([GHOperation.orgSecretRepositories, .orgVariableRepositories, .orgSecretSet, .orgSecretDelete,
                  .orgVariableSet, .orgVariableDelete].map(\.rawValue) == ["B14", "B15", "C10", "C11", "C12", "C13"])
    }
}
