import DestinationKit
import Foundation
import GitHubKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Connect Azure (tasks/todo.md B8b2): the `az` requirements, the subscriptions and their vaults,
/// and the import of the checked vaults as Key Vaults of their own, through the scripted `az`
/// and Key Vault answers (nothing runs, nothing reaches Azure).
@MainActor
@Suite("Connect Azure")
struct ConnectAzureTests {
    static let production = FakeAzureOutput.Subscription(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Example Production",
        tenantID: UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!,
        isDefault: true
    )
    static let productionSubscription = KeyVaultSubscriptionModel(id: production.id, name: production.name)
    static let retired = FakeAzureOutput.Subscription(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        name: "Example Retired",
        tenantID: UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!,
        state: "Disabled"
    )

    /// ConnectViewModelTests' gh, plus an `az` that lists two vaults in Example Production:
    /// kv-example-prod answers with one secret, kv-example-shared is not scripted (its reads fail).
    static func scripted() async throws -> TestHarness {
        let harness = try await ConnectViewModelTests.scripted()
        try harness.installFakeAZ()
        harness.runner.stub(argumentsPrefix: ["account", "list"], with: .success(FakeAzureOutput.accountList([production, retired])))
        harness.runner.stub(
            argumentsPrefix: ["keyvault", "list"],
            with: .success(FakeAzureOutput.keyVaultList(["kv-example-prod", "kv-example-shared"], subscriptionID: production.id))
        )
        harness.transport.stubKeyVault("kv-example-prod", secrets: ["DATABASE-URL": "postgres://example"])
        return harness
    }

    @Test func vaultsAreListedCheckedAndDisabledSubscriptionsLeftOut() async throws {
        let harness = try await Self.scripted()
        let connect = harness.app.makeConnectViewModel()
        await connect.load()
        connect.goToAzure()
        #expect(connect.step == .azure)
        await connect.azure.load()

        #expect(connect.azure.requirement == .ready)
        #expect(connect.azure.subscriptions.map(\.name) == ["Example Production"])
        #expect(connect.azure.selectedVaults.map(\.name) == ["kv-example-prod", "kv-example-shared"])
        #expect(ConnectCopy.vaultsSelected(1) == "1 vault selected · Secrets with values")

        connect.backToGitHub()
        #expect(connect.step == .github)
    }

    /// Continue on Azure imports GitHub's checked sources, then each checked vault with its
    /// values; a vault that cannot be read is named and the rest is kept.
    @Test func continueImportsGitHubThenTheVaultsAsSourcesOfTheirOwn() async throws {
        let harness = try await Self.scripted()
        let connect = harness.app.makeConnectViewModel()
        await connect.load()
        connect.goToAzure()
        await connect.azure.load()
        await connect.importSelected()

        let summary = try #require(connect.summary)
        #expect(summary.organizationCount == 1)
        #expect(summary.keyVaultCount == 1)
        #expect(summary.keyVaultSecretCount == 1)
        #expect(summary.failedNames == ["user-a/dotfiles", "kv-example-shared"])
        #expect(summary.totalSecretCount == 3)

        let vaults = try harness.data.destinations.destinations(repositoryID: nil)
        #expect(vaults.map(\.target.displayName) == ["kv-example-prod", "kv-example-shared"])
        let prod = try #require(vaults.first)
        #expect(prod.target == .azureKeyVault(vaultName: "kv-example-prod", tenantID: "00000000-0000-0000-0000-0000000000a1"))
        #expect(prod.subscription == Self.productionSubscription, "the sidebar groups it under its subscription")
        let item = try #require(try harness.data.destinations.items(destinationID: prod.id).first)
        #expect(item.name == "DATABASE_URL")
        let value = try harness.data.destinations.reveal(item.id)
        defer { value.wipe() }
        #expect(value.utf8String() == "postgres://example")
    }

    @Test func importingAgainReusesTheVault() async throws {
        let harness = try await Self.scripted()
        // Saved before 1.0 D6c6: Connect gives the vault it reuses its subscription.
        let saved = try harness.data.destinations.createDestination(
            repositoryID: nil,
            target: .azureKeyVault(vaultName: "kv-example-prod", tenantID: Self.production.tenantID.uuidString.lowercased()),
            stage: nil
        )
        for _ in 0..<2 {
            let connect = harness.app.makeConnectViewModel()
            await connect.load()
            connect.goToAzure()
            await connect.azure.load()
            connect.azure.toggle(try #require(connect.azure.selectedVaults.last))
            await connect.importSelected()
            #expect(connect.summary?.keyVaultCount == 1)
        }
        #expect(try harness.data.destinations.destinations(repositoryID: nil).map(\.id) == [saved])
        #expect(try harness.data.destinations.destination(saved)?.subscription == Self.productionSubscription)
    }

    /// 1.0 D6c6: a vault without a saved subscription gets it from its Refresh (no `az` at launch).
    @Test func refreshingAVaultSavesItsSubscription() async throws {
        let harness = try await Self.scripted()
        let destinations = harness.data.destinations
        let id = try destinations.createDestination(
            repositoryID: nil,
            target: .azureKeyVault(vaultName: "kv-example-prod", tenantID: nil),
            stage: nil
        )
        let model = DestinationDetailViewModel(
            destination: try #require(try destinations.destination(id)),
            dependencies: harness.dependencies(recorder: ActionRecorder())
        ) {
            try? destinations.destination(id)
        }
        #expect(try destinations.destination(id)?.subscription == nil)
        model.refreshNow()
        #expect(await TestFixtures.eventually { (try? destinations.destination(id)?.subscription) == Self.productionSubscription })
    }

    @Test func skipImportsGitHubOnlyAndNothingCheckedOpensTheVault() async throws {
        let harness = try await Self.scripted()
        let connect = harness.app.makeConnectViewModel()
        await connect.load()
        connect.goToAzure()
        await connect.azure.load()
        await connect.skipAzure()
        #expect(connect.summary?.keyVaultCount == 0)
        #expect(connect.summary?.organizationCount == 1)
        #expect(try harness.data.destinations.destinations(repositoryID: nil).isEmpty)

        let empty = harness.app.makeConnectViewModel()
        await empty.load()
        for source in empty.selectedSources {
            empty.toggle(source)
        }
        empty.goToAzure()
        await empty.skipAzure()
        #expect(empty.summary == nil)
        #expect(!harness.app.isFirstConnectPending)
    }

    /// `az account list` printing `[]` means signed out: `az login` is offered, Copy only.
    @Test func signedOutAZAsksForAZLoginAndRequirementsMapTheErrors() async throws {
        let harness = try await Self.scripted()
        harness.runner.replaceStub(argumentsPrefix: ["account", "list"], with: .success("[]"))
        let azure = harness.app.makeConnectViewModel().azure
        await azure.load()
        #expect(azure.requirement == .notSignedIn)
        #expect(azure.commands == ["az login"])
        #expect(azure.runs.runnable("az login") == nil)
        #expect(azure.subscriptions.isEmpty)

        #expect(ConnectAzureModel.requirement(for: .azNotInstalled) == .notInstalled)
        #expect(ConnectAzureModel.requirement(for: .azUntrusted(path: "/tmp/az")) == .untrusted(path: "/tmp/az"))
        if case .failed = ConnectAzureModel.requirement(for: .azFailed(exitCode: 1)) {} else {
            Issue.record("Another az failure shows as failed")
        }
    }

    @Test func aLockForgetsTheListedVaults() async throws {
        let harness = try await Self.scripted()
        let connect = harness.app.makeConnectViewModel()
        await connect.load()
        connect.goToAzure()
        await connect.azure.load()
        harness.app.lock(trigger: .manual)
        #expect(connect.step == .github)
        #expect(connect.azure.subscriptions.isEmpty)
        #expect(connect.azure.selection.isEmpty)
        #expect(!connect.azure.hasLoaded)
    }
}
