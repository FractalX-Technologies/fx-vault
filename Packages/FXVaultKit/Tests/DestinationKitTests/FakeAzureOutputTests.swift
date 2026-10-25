import Foundation
import GitHubKit
import Testing
@testable import DestinationKit
import VaultCore

/// ``FakeAzureOutput`` feeds AppTests and the UI-testing host: what it prints must decode
/// through the real `az` and Key Vault parsers, or those tests would exercise another format.
@Suite("Fake Azure output")
struct FakeAzureOutputTests {
    static let subscription = FakeAzureOutput.Subscription(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Example Production",
        tenantID: UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!,
        isDefault: true
    )

    @Test func listingsDecodeThroughTheDiscoveryParsers() throws {
        let subscriptions = try AzureCLIDiscovery.parseSubscriptions(stdout: SecretBytes(utf8: FakeAzureOutput.accountList([Self.subscription])))
        #expect(subscriptions.map(\.name) == ["Example Production"])
        #expect(subscriptions.first?.tenantID == "00000000-0000-0000-0000-0000000000a1")
        #expect(subscriptions.first?.isDefault == true)
        #expect(FakeAzureOutput.syntheticID(0xA1).uuidString == "00000000-0000-0000-0000-0000000000A1")

        let vaults = try AzureCLIDiscovery.parseKeyVaults(stdout: SecretBytes(utf8: FakeAzureOutput.keyVaultList(
            ["kv-example-prod", "kv-example-shared"],
            subscriptionID: Self.subscription.id
        )))
        #expect(vaults.map(\.name) == ["kv-example-prod", "kv-example-shared"])
        #expect(vaults.first?.vaultURI?.absoluteString == "https://kv-example-prod.vault.azure.net/")
    }

    @Test func tokenAndSecretsDecodeThroughTheKeyVaultRemote() async throws {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: ["account", "get-access-token"], with: .success(FakeAzureOutput.accessToken(expiresOn: .distantFuture)))
        let tokens = AzureCLITokenProvider(
            cli: AzureCLIRunner(
                runner: runner,
                locator: AzureCLILocator(fileInspector: AzureCLITests.homebrewInspector()),
                identity: AzureCLITests.identity,
                shell: AzureCLITests.shell,
                workingDirectory: AzureCLITests.workingDirectory
            ),
            clock: InstantClock()
        )
        let token = try await tokens.token(tenantID: nil)
        #expect(token.testText == "fake-azure-token")

        let transport = FakeHTTPTransport()
        let vault = TestValues.vaultName
        transport.stubKeyVault(vault, secrets: ["DATABASE-URL": "postgres://a"])
        let remote = try TestValues.keyVault(transport)
        let items = try await remote.list()
        #expect(items.map(\.name) == ["DATABASE_URL"])
        let value = try await remote.readValue(of: try #require(items.first))
        #expect(value.testText == "postgres://a")
    }
}
