import Darwin
import Foundation
import GitHubKit
import Testing
@testable import DestinationKit
import VaultCore

/// `az account list` and `az keyvault list` through `FakeCommandRunner` and the Homebrew layout
/// of ``AzureCLITests`` (nothing runs). Fixtures in `Fixtures/az` use placeholder names and ids.
@Suite("Azure discovery")
struct AzureDiscoveryTests {
    private static let production = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let staging = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private static let accountList = ["account", "list"]
    private static let keyVaultList = ["keyvault", "list"]

    private static func discovery(_ runner: FakeCommandRunner, inspector: FakeGHFileInspector = AzureCLITests.homebrewInspector()) -> AzureCLIDiscovery {
        AzureCLIDiscovery(cli: AzureCLIRunner(
            runner: runner,
            locator: AzureCLILocator(fileInspector: inspector),
            identity: AzureCLITests.identity,
            shell: AzureCLITests.shell,
            workingDirectory: AzureCLITests.workingDirectory
        ))
    }

    private static func subscriptionJSON(id: String, tenant: String = "00000000-0000-0000-0000-0000000000a1", isDefault: Bool = false) -> String {
        #"{"id":"\#(id)","name":"Example","tenantId":"\#(tenant)","state":"Enabled","isDefault":\#(isDefault)}"#
    }

    // MARK: - Commands

    @Test func runsBothListingsWithExactArgvThroughTheTrustedAZ() async throws {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: Self.accountList, with: .success(try Fixture.string("az/account-list.json")))
        runner.stub(argumentsPrefix: Self.keyVaultList, with: .success(try Fixture.string("az/keyvault-list.json")))
        let discovery = Self.discovery(runner)
        _ = try await discovery.subscriptions()
        _ = try await discovery.keyVaults(subscriptionID: Self.production)

        #expect(runner.invocations.map(\.arguments) == [
            ["account", "list", "--output", "json"],
            ["keyvault", "list", "--resource-type", "vault", "--subscription", "00000000-0000-0000-0000-000000000001", "--output", "json"],
        ])
        for invocation in runner.invocations {
            #expect(invocation.executablePath == AzureCLITests.cellarAZ, "the checked, resolved path runs")
            #expect(invocation.stdin.isEmpty)
            #expect(invocation.timeout == Timeouts.azList)
            #expect(invocation.workingDirectory == AzureCLITests.workingDirectory)
            #expect(invocation.environment == AzureCLIRunner.environment(identity: AzureCLITests.identity, shell: AzureCLITests.shell, azureConfigDirectory: nil))
        }
    }

    @Test func missingOrUntrustedAZStopsBeforeRunning() async {
        let runner = FakeCommandRunner()
        await #expect(throws: DestinationError.azNotInstalled) {
            try await Self.discovery(runner, inspector: FakeGHFileInspector()).subscriptions()
        }
        await #expect(throws: DestinationError.azUntrusted(path: AzureCLITests.homebrewAZ)) {
            try await Self.discovery(runner, inspector: AzureCLITests.homebrewInspector(owner: 502)).keyVaults(subscriptionID: Self.production)
        }
        #expect(runner.invocations.isEmpty)
    }

    // MARK: - Subscriptions

    @Test func parsesSubscriptions() throws {
        let subscriptions = try AzureCLIDiscovery.parseSubscriptions(stdout: TestValues.secret(try Fixture.string("az/account-list.json")))
        #expect(subscriptions.map(\.name) == ["Example Production", "Example Staging", "Example Labs", "Example Archive"])
        #expect(subscriptions.map(\.state) == [.enabled, .warned, .pastDue, .disabled])
        #expect(subscriptions.map(\.isDefault) == [true, false, false, false])
        #expect(subscriptions[0].id == Self.production)
        #expect(subscriptions[0].tenantID == "00000000-0000-0000-0000-0000000000a1", "tenants are lowercased for DestinationTargetModel")
        #expect(AzureSubscriptionState(listed: "Expired") == .other)
        #expect(subscriptions.map(\.tenantName) == ["Example", nil, nil, nil], "only the first entry lists tenantDisplayName")
    }

    /// Settings › Accounts shows the tenant name: invisible and bidi characters go, and a name
    /// left empty is no name.
    @Test func aTenantNameIsCleanedOrLeftOut() throws {
        func listed(_ name: String) -> String {
            #"[{"id":"00000000-0000-0000-0000-000000000009","name":"Example","tenantId":"00000000-0000-0000-0000-0000000000a1","tenantDisplayName":"\#(name)","state":"Enabled","isDefault":true}]"#
        }
        let cleaned = try AzureCLIDiscovery.parseSubscriptions(stdout: TestValues.secret(listed("  Example\u{202E} Labs ")))
        #expect(cleaned.map(\.tenantName) == ["Example Labs"])
        let blank = try AzureCLIDiscovery.parseSubscriptions(stdout: TestValues.secret(listed(" \u{200B} ")))
        #expect(blank.map(\.tenantName) == [nil])
    }

    /// A subscription name is cleaned like the tenant's; one with nothing left shows its id.
    @Test func aSubscriptionNameIsCleaned() throws {
        func listed(_ name: String) -> String {
            #"[{"id":"00000000-0000-0000-0000-000000000009","name":"\#(name)","tenantId":"00000000-0000-0000-0000-0000000000a1","state":"Enabled","isDefault":true}]"#
        }
        let cleaned = try AzureCLIDiscovery.parseSubscriptions(stdout: TestValues.secret(listed(" Example\u{202E} Production\u{200B} ")))
        #expect(cleaned.map(\.name) == ["Example Production"])
        let blank = try AzureCLIDiscovery.parseSubscriptions(stdout: TestValues.secret(listed("\u{200B}\u{202E}")))
        #expect(blank.map(\.name) == ["00000000-0000-0000-0000-000000000009"])
    }

    @Test func aSubscriptionListedTwiceKeepsTheDefaultEntry() throws {
        let id = "00000000-0000-0000-0000-000000000009"
        let json = "[\(Self.subscriptionJSON(id: id)),\(Self.subscriptionJSON(id: id, tenant: "00000000-0000-0000-0000-0000000000a2", isDefault: true))]"
        let subscriptions = try AzureCLIDiscovery.parseSubscriptions(stdout: TestValues.secret(json))
        #expect(subscriptions.count == 1)
        #expect(subscriptions.first?.isDefault == true)
        #expect(subscriptions.first?.tenantID == "00000000-0000-0000-0000-0000000000a2")
    }

    @Test func noSubscriptionsMeansNotSignedIn() async {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: Self.accountList, with: .success("[]\n"))
        await #expect(throws: DestinationError.azNotSignedIn) {
            try await Self.discovery(runner).subscriptions()
        }
    }

    @Test(arguments: [
        "",
        "not json",
        #"{"id":"00000000-0000-0000-0000-000000000001"}"#,
        #"[{"id":"--subscription","name":"Example","tenantId":"00000000-0000-0000-0000-0000000000a1","state":"Enabled","isDefault":true}]"#,
        #"[{"id":"00000000-0000-0000-0000-000000000001","name":"Example","tenantId":"example.onmicrosoft.com","state":"Enabled","isDefault":true}]"#,
        #"[{"id":"00000000-0000-0000-0000-000000000001","tenantId":"00000000-0000-0000-0000-0000000000a1","state":"Enabled","isDefault":true}]"#,
        #"[{"id":"00000000-0000-0000-0000-000000000001","name":"Example","tenantId":"00000000-0000-0000-0000-0000000000a1","isDefault":true}]"#,
        #"[{"id":"00000000-0000-0000-0000-000000000001","name":"Example","tenantId":"00000000-0000-0000-0000-0000000000a1","state":"Enabled","isDefault":"true"}]"#,
    ])
    func malformedSubscriptionsAreDecoding(stdout: String) {
        #expect(throws: DestinationError.decoding) {
            try AzureCLIDiscovery.parseSubscriptions(stdout: TestValues.secret(stdout))
        }
    }

    // MARK: - Key Vaults

    @Test func parsesKeyVaultsAndKeepsOnlyTheirOwnURI() throws {
        let vaults = try AzureCLIDiscovery.parseKeyVaults(stdout: TestValues.secret(try Fixture.string("az/keyvault-list.json")))
        #expect(vaults.map(\.name) == ["kv-example-prod", "kv-example-shared", "kv-example-cn", "kv-example-mismatch"])
        #expect(vaults[0].resourceGroup == "rg-example-prod")
        #expect(vaults[0].location == "westeurope")
        #expect(vaults[0].vaultURI == URL(string: "https://kv-example-prod.vault.azure.net/"))
        #expect(vaults[1].vaultURI == nil, "az listed no properties")
        #expect(vaults[2].vaultURI == nil, "another cloud's host")
        #expect(vaults[3].vaultURI == nil, "another vault's host")
        #expect(try AzureCLIDiscovery.parseKeyVaults(stdout: TestValues.secret("[]")).isEmpty)
    }

    @Test(arguments: [
        "not json",
        #"{"name":"kv-example-prod"}"#,
        #"[{"name":"kv--example","resourceGroup":"rg","location":"westeurope"}]"#,
        #"[{"name":"kv-example.evil.net","resourceGroup":"rg","location":"westeurope"}]"#,
        #"[{"name":"kv-example-prod","location":"westeurope"}]"#,
        #"[{"name":"kv-example-prod","resourceGroup":"rg"}]"#,
    ])
    func malformedKeyVaultsAreDecoding(stdout: String) {
        #expect(throws: DestinationError.decoding) {
            try AzureCLIDiscovery.parseKeyVaults(stdout: TestValues.secret(stdout))
        }
    }

    // MARK: - Failures

    @Test(arguments: [
        ("ERROR: Please run 'az login' to setup account.", DestinationError.azNotSignedIn),
        ("ERROR: AADSTS50076: Due to a configuration change made by your administrator, you must use multi-factor authentication.\nRun the command below to authenticate interactively:\naz login --tenant 00000000-0000-0000-0000-0000000000a2", .azNotSignedIn),
        ("ERROR: (AuthorizationFailed) The client 'user-a@example.com' does not have authorization to perform action 'Microsoft.KeyVault/vaults/read' over scope '/subscriptions/00000000-0000-0000-0000-000000000001'.\nCode: AuthorizationFailed", .forbidden),
        ("ERROR: The command failed with an unexpected error.", .azFailed(exitCode: 1)),
    ])
    func keyVaultFailuresAreClassifiedFromStderr(stderr: String, expected: DestinationError) async {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: Self.keyVaultList, with: .failure(stderr: stderr))
        await #expect(throws: expected) {
            try await Self.discovery(runner).keyVaults(subscriptionID: Self.production)
        }
    }

    @Test func timeoutsLaunchFailuresTruncationAndCancellation() async {
        let cases: [(FakeCommandRunner.Response, DestinationError)] = [
            (FakeCommandRunner.Response(exitCode: 15, didTimeOut: true), .timeout),
            (FakeCommandRunner.Response(error: .launchFailed(errno: ENOENT)), .azNotInstalled),
            (FakeCommandRunner.Response(error: .launchFailed(errno: EACCES)), .azFailed(exitCode: AzureCLIRunner.launchFailedExitCode)),
            (FakeCommandRunner.Response(stdout: Data("[{\"id\":".utf8), isStdoutTruncated: true), .responseTooLarge),
            (FakeCommandRunner.Response(error: .cancelled), .cancelled),
        ]
        for (response, expected) in cases {
            let runner = FakeCommandRunner()
            runner.stub(argumentsPrefix: Self.accountList, with: response)
            await #expect(throws: expected) {
                try await Self.discovery(runner).subscriptions()
            }
        }
    }

    // MARK: - Discover

    @Test func oneSubscriptionsFailureStaysOnItsEntry() async throws {
        let runner = FakeCommandRunner()
        let ids = [Self.production, Self.staging].map { $0.uuidString.lowercased() }
        runner.stub(argumentsPrefix: Self.accountList, with: .success("[\(Self.subscriptionJSON(id: ids[0], isDefault: true)),\(Self.subscriptionJSON(id: ids[1]))]"))
        runner.enqueue(.success(try Fixture.string("az/keyvault-list.json")), matching: { $0.contains(ids[0]) })
        runner.enqueue(.failure(stderr: "ERROR: (AuthorizationFailed) no role"), matching: { $0.contains(ids[1]) })

        let tree = try await Self.discovery(runner).discover()
        #expect(tree.map(\.subscription.id) == [Self.production, Self.staging])
        #expect((try? tree[0].vaults.get())?.count == 4)
        #expect(tree[1].vaults == .failure(.forbidden))
        #expect(runner.invocations.map { $0.arguments.first } == ["account", "keyvault", "keyvault"], "one az at a time, in order")
    }

    @Test func discoverFailsWhenSubscriptionsFailOrOnCancellation() async {
        let signedOut = FakeCommandRunner()
        signedOut.stub(argumentsPrefix: Self.accountList, with: .failure(stderr: "ERROR: Please run 'az login' to setup account."))
        await #expect(throws: DestinationError.azNotSignedIn) {
            try await Self.discovery(signedOut).discover()
        }
        #expect(signedOut.invocations.count == 1)

        let cancelled = FakeCommandRunner()
        cancelled.stub(argumentsPrefix: Self.accountList, with: .success("[\(Self.subscriptionJSON(id: Self.production.uuidString))]"))
        cancelled.stub(argumentsPrefix: Self.keyVaultList, with: FakeCommandRunner.Response(error: .cancelled))
        await #expect(throws: DestinationError.cancelled) {
            try await Self.discovery(cancelled).discover()
        }
    }
}
