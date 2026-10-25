import Foundation
import Testing
@testable import GitHubKit
import VaultCore

/// Organization secrets and variables (1.0, tasks/todo.md B5): B12 and B13 list them with their
/// visibility; secrets are names only.
@Suite("Organization listings")
struct OrgListingTests {
    private func output(_ operation: GHOperation, _ json: String) -> GHCommandOutput {
        var data = Data(json.utf8)
        return GHCommandOutput(operation: operation, stdout: SecretBytes(wipingSource: &data))
    }

    @Test func listsUseTheOrgFlagAndAskForTheVisibility() throws {
        let secrets = try GHSecretsCommands.list(organization: "example-org")
        #expect(secrets.arguments == ["secret", "list", "--org=example-org", "--json", "name,updatedAt,visibility,numSelectedRepos"])
        #expect(secrets.operation == .orgSecretList)
        #expect(!secrets.operation.isWrite)
        let variables = try GHVariablesCommands.list(organization: "example-org")
        #expect(variables.arguments == [
            "variable", "list", "--org=example-org", "--json", "name,value,updatedAt,createdAt,visibility,numSelectedRepos",
        ])
        #expect(variables.logTemplate == "variable list --org={o} --json name,value,updatedAt,createdAt,visibility,numSelectedRepos")
        #expect(throws: GHError.self) { try GHSecretsCommands.list(organization: "-example") }
        #expect(throws: GHError.self) { try GHVariablesCommands.list(organization: "example/org") }
    }

    @Test func secretsDecodeTheirVisibility() throws {
        let secrets = try GHSecretsCommands.decodeList(output(.orgSecretList, """
        [{"name":"NPM_TOKEN","numSelectedRepos":0,"selectedReposURL":"","updatedAt":"2026-08-02T10:00:00Z","visibility":"all"},
         {"name":"STRIPE_KEY","numSelectedRepos":3,"selectedReposURL":"https://api.github.com/orgs/example-org/actions/secrets/STRIPE_KEY/repositories","updatedAt":"2026-10-12T10:00:00Z","visibility":"selected"},
         {"name":"SONAR_TOKEN","numSelectedRepos":0,"selectedReposURL":"","updatedAt":"2026-08-02T10:00:00Z","visibility":"private"}]
        """))
        #expect(secrets.map(\.visibility) == [.all, .selected, .private])
        #expect(secrets[1].numSelectedRepos == 3)
    }

    @Test func variablesDecodeTheirValueAndVisibility() throws {
        let variables = try GHVariablesCommands.decodeList(output(.orgVariableList, """
        [{"createdAt":"2026-08-01T10:00:00Z","name":"REGION","numSelectedRepos":2,"selectedReposURL":"x","updatedAt":"2026-08-02T10:00:00Z","value":"eu-west","visibility":"selected"}]
        """))
        defer { variables.forEach { $0.wipe() } }
        #expect(variables.first?.value.utf8String() == "eu-west")
        #expect(variables.first?.visibility == .selected)
        #expect(variables.first?.numSelectedRepos == 2)
    }

    @Test func anUnknownVisibilityIsMalformed() {
        #expect(throws: GHError.malformedOutput) {
            try GHSecretsCommands.decodeList(output(.orgSecretList, #"[{"name":"A","updatedAt":"2026-08-02T10:00:00Z","visibility":"public"}]"#))
        }
    }

    @Test func repositoryListingsCarryNoVisibility() throws {
        let secrets = try GHSecretsCommands.decodeList(output(.secretList, #"[{"name":"A","updatedAt":"2026-08-02T10:00:00Z"}]"#))
        #expect(secrets.first?.visibility == nil)
    }
}
