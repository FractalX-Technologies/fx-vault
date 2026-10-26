import DestinationKit
import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Settings › Accounts › Azure (1.0 S1b; board Settings-Accounts): a row per tenant from the
/// saved vaults and `az account list`, the `az` logins to copy, and Choose Vaults… over Connect
/// Azure's list, through the scripted `az` and Key Vault (nothing runs, nothing reaches Azure).
@MainActor
@Suite("Azure accounts in Settings")
struct AzureAccountsTests {
    static let example = "00000000-0000-0000-0000-0000000000a1"
    static let labs = "00000000-0000-0000-0000-0000000000a2"
    static let tools = "00000000-0000-0000-0000-0000000000a3"
    static let production = FakeAzureOutput.Subscription(
        id: FakeAzureOutput.syntheticID(0x01),
        name: "Example Production",
        tenantID: FakeAzureOutput.syntheticID(0xA1),
        tenantName: "Example",
        isDefault: true
    )
    static let productionSubscription = KeyVaultSubscriptionModel(id: production.id, name: production.name)

    /// An unlocked vault, gh, and an `az` signed in to Example with two vaults in Example
    /// Production: kv-example-prod answers with one secret, kv-example-shared is not scripted.
    static func scripted() async throws -> TestHarness {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        try harness.installFakeGH()
        try harness.installFakeAZ()
        harness.runner.stub(argumentsPrefix: ["account", "list"], with: .success(FakeAzureOutput.accountList([production])))
        harness.runner.stub(
            argumentsPrefix: ["keyvault", "list"],
            with: .success(FakeAzureOutput.keyVaultList(["kv-example-prod", "kv-example-shared"], subscriptionID: production.id))
        )
        harness.transport.stubKeyVault("kv-example-prod", secrets: ["DATABASE-URL": "postgres://example"])
        return harness
    }

    /// One id per subscription name, as Azure gives them.
    private static let subscriptionIDs = [
        "Example Production": FakeAzureOutput.syntheticID(0x01),
        "Example Staging": FakeAzureOutput.syntheticID(0x02),
        "Labs Dev": FakeAzureOutput.syntheticID(0x03),
    ]

    private static func vault(_ name: String, tenant: String?, subscription: String?) -> DestinationModel {
        DestinationModel(
            repositoryID: nil,
            target: .azureKeyVault(vaultName: name, tenantID: tenant),
            stage: nil,
            sortOrder: 0,
            subscription: subscription.map { KeyVaultSubscriptionModel(id: subscriptionIDs[$0] ?? UUID(), name: $0) },
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private static func subscription(_ name: String, tenant: String, tenantName: String? = nil, isDefault: Bool = false) -> AzureSubscriptionModel {
        AzureSubscriptionModel(id: UUID(), name: name, tenantID: tenant, tenantName: tenantName, state: .enabled, isDefault: isDefault)
    }

    // MARK: - Rows

    @Test func aRowPerTenantFromTheSavedVaultsAndAZ() {
        let vaults = [
            Self.vault("kv-prod-a", tenant: Self.example.uppercased(), subscription: "Example Production"),
            Self.vault("kv-prod-b", tenant: Self.example, subscription: "Example Production"),
            Self.vault("kv-staging", tenant: Self.example, subscription: "Example Staging"),
            Self.vault("kv-labs", tenant: Self.labs, subscription: "Labs Dev"),
            // Saved without a tenant or a subscription: az's default tenant, "other".
            Self.vault("kv-old", tenant: nil, subscription: nil),
        ]
        let listed = [
            Self.subscription("Example Staging", tenant: Self.example),
            Self.subscription("Example Production", tenant: Self.example, tenantName: "Example", isDefault: true),
            Self.subscription("Tools", tenant: Self.tools, tenantName: "Example Tools"),
        ]
        let rows = AzureTenantRowModel.rows(vaults: vaults, listed: listed, requirement: .ready)
        #expect(rows.map(\.title) == ["Example", "Example Tools", Self.labs])
        #expect(rows.map(\.signIn) == [.signedIn, .signedIn, .notSignedIn])
        #expect(rows[0].subline == "Example Production · 2 vaults, Example Staging · 1 vault, 1 other vault")
        #expect(rows[1].subline == "No vaults in FX Vault", "a signed-in tenant without vaults still offers Choose Vaults…")
        #expect(rows[2].subline == "Not signed in · Labs Dev · 1 vault")
        #expect(rows[2].loginCommand == "az login --tenant \(Self.labs)")
    }

    @Test func withoutAZTheRowsSayNoMore() {
        let vaults = [Self.vault("kv-old", tenant: nil, subscription: nil), Self.vault("kv-labs", tenant: Self.labs, subscription: nil)]
        let signedOut = AzureTenantRowModel.rows(vaults: vaults, listed: [], requirement: .notSignedIn)
        // Titles in Finder order: a tenant id before a name.
        #expect(signedOut.map(\.title) == [Self.labs, "Default tenant"])
        #expect(signedOut.map(\.subline) == ["Not signed in · 1 vault", "Not signed in · 1 vault"])
        #expect(signedOut.map(\.loginCommand) == ["az login --tenant \(Self.labs)", "az login"])

        let missing = AzureTenantRowModel.rows(vaults: vaults, listed: [], requirement: .notInstalled)
        #expect(missing.map(\.signIn) == [.unknown, .unknown])
        #expect(missing.map(\.subline) == ["1 vault", "1 vault"])
    }

    // MARK: - The group

    @Test func theGroupListsTheTenantAndChooseVaultsAddsOnlyNewVaults() async throws {
        let harness = try await Self.scripted()
        _ = try harness.data.destinations.createDestination(
            repositoryID: nil,
            target: .azureKeyVault(vaultName: "kv-example-shared", tenantID: Self.example),
            stage: nil,
            subscription: Self.productionSubscription
        )
        let azure = AzureAccountsViewModel(app: harness.app)
        await azure.load()
        #expect(azure.requirement == .ready)
        let tenant = try #require(azure.tenants.first)
        #expect(azure.tenants.count == 1)
        #expect(tenant.title == "Example" && tenant.signIn == .signedIn)
        #expect(tenant.subline == "Example Production · 1 vault")
        #expect(azure.showsSignOut)
        #expect(azure.setupCommands.isEmpty)

        azure.chooseVaults(tenant)
        let chooser = try #require(azure.chooser)
        #expect(chooser.scope == .tenant(Self.example))
        await chooser.load()
        #expect(chooser.subscriptions.flatMap(\.vaults).map(\.name) == ["kv-example-prod", "kv-example-shared"])
        #expect(chooser.savedVaultIDs == ["kv-example-shared"])
        #expect(chooser.selectedVaults.isEmpty, "Settings checks nothing new by itself")
        let shared = try #require(chooser.subscriptions.first?.vaults.last)
        chooser.toggle(shared)
        #expect(chooser.selectedVaults.isEmpty, "a vault already in FX Vault is not imported again")
        chooser.toggle(try #require(chooser.subscriptions.first?.vaults.first))

        await azure.addChosenVaults()
        #expect(azure.chooser == nil)
        #expect(azure.importResult == ConnectAzureModel.ImportResult(vaultCount: 1, secretCount: 1, failedNames: []))
        #expect(AzureAccountsSection.resultText(try #require(azure.importResult)) == "Added 1 vault with 1 secret.")
        #expect(azure.tenants.first?.subline == "Example Production · 2 vaults")
        let saved = try harness.data.destinations.destinations(repositoryID: nil)
        #expect(saved.map(\.target.displayName).sorted() == ["kv-example-prod", "kv-example-shared"])
        #expect(saved.first { $0.target.displayName == "kv-example-prod" }?.subscription == Self.productionSubscription)
    }

    @Test func signedOutTheGroupGivesTheLoginsToCopy() async throws {
        let harness = try await Self.scripted()
        harness.runner.replaceStub(argumentsPrefix: ["account", "list"], with: .success("[]"))
        let azure = AzureAccountsViewModel(app: harness.app)
        await azure.load()
        #expect(azure.requirement == .notSignedIn)
        #expect(azure.tenants.isEmpty)
        #expect(azure.setupCommands == ["az login"])
        #expect(!azure.showsSignOut)

        _ = try harness.data.destinations.createDestination(
            repositoryID: nil,
            target: .azureKeyVault(vaultName: "kv-example-prod", tenantID: Self.example),
            stage: nil,
            subscription: Self.productionSubscription
        )
        await azure.checkAgain()
        let tenant = try #require(azure.tenants.first)
        #expect(tenant.signIn == .notSignedIn)
        #expect(azure.setupCommands.isEmpty, "the tenant's row gives its own login")
        azure.chooseVaults(tenant)
        #expect(azure.chooser == nil, "Choose Vaults… needs a signed-in tenant")

        azure.copy(tenant.loginCommand)
        #expect(harness.pasteboardString == "az login --tenant \(Self.example)")
        #expect(azure.copiedCommand == tenant.loginCommand)
        #expect(AzureAccountsCopy.copied(AzureAccountsCopy.logoutCommand) == "Copied az logout. Run it in Terminal, then Check Again.")
        await azure.checkAgain()
        #expect(azure.copiedCommand == nil)
    }

    @Test func aLockClearsTheGroupAndItsSheet() async throws {
        let harness = try await Self.scripted()
        let accounts = AccountsSettingsViewModel(app: harness.app)
        let azure = accounts.azure
        await azure.load()
        azure.chooseVaults(try #require(azure.tenants.first))
        azure.copy(AzureAccountsCopy.logoutCommand)
        #expect(azure.chooser != nil)

        harness.app.lock(trigger: .manual)
        #expect(azure.tenants.isEmpty)
        #expect(azure.chooser == nil)
        #expect(azure.requirement == nil && azure.copiedCommand == nil)
        await azure.load()
        #expect(azure.tenants.isEmpty, "nothing is listed while locked")
    }

    /// A lock while Add Vaults reads the first vault, then a quick unlock and a new sheet: the
    /// rest is not imported, and the new sheet is left alone.
    @Test(.timeLimit(.minutes(1))) func aLockDuringAddVaultsStopsTheImportAndLeavesALaterSheet() async throws {
        let harness = try await Self.scripted()
        // The first list answers 429: the import waits on the test's clock until it advances.
        harness.transport.enqueue(
            .status(429, headers: ["Retry-After": "1"]),
            method: .get,
            pathPrefix: "/secrets",
            host: "kv-example-prod.vault.azure.net"
        )
        // Held: its lock observer resets the group.
        let accounts = AccountsSettingsViewModel(app: harness.app)
        let azure = accounts.azure
        await azure.load()
        azure.chooseVaults(try #require(azure.tenants.first))
        let chooser = try #require(azure.chooser)
        await chooser.load()
        for vault in chooser.subscriptions.flatMap(\.vaults) {
            chooser.toggle(vault)
        }
        #expect(chooser.selectedVaults.map(\.name) == ["kv-example-prod", "kv-example-shared"])

        let sleepers = harness.clock.sleeperCount
        let importing = Task { await azure.addChosenVaults() }
        await harness.clock.waitForSleepers(count: sleepers + 1)
        harness.app.lock(trigger: .manual)
        try await harness.vaultManager.unlock(password: testPassword)
        harness.app.didUnlock()
        await azure.load()
        azure.chooseVaults(try #require(azure.tenants.first))
        let later = try #require(azure.chooser)
        harness.clock.advance(by: .seconds(1))
        await importing.value

        #expect(azure.chooser === later, "the sheet opened after the lock stays open")
        #expect(azure.importResult == nil && !azure.isImporting && azure.importingName == nil)
        let saved = try harness.data.destinations.destinations(repositoryID: nil).map(\.target.displayName)
        #expect(!saved.contains("kv-example-shared"), "nothing after the lock is imported")
        withExtendedLifetime(accounts) {}
    }

    @Test func aTenantThatIsNotAnIDLogsInWithoutIt() {
        #expect(AzureAccountsCopy.loginCommand(tenantID: Self.labs) == "az login --tenant \(Self.labs)")
        #expect(AzureAccountsCopy.loginCommand(tenantID: "contoso.onmicrosoft.com") == "az login --tenant contoso.onmicrosoft.com")
        #expect(AzureAccountsCopy.loginCommand(tenantID: "x; rm -rf ~") == "az login")
        #expect(AzureAccountsCopy.loginCommand(tenantID: nil) == "az login")
    }

    /// Two vaults that saved one subscription under different names count as one subscription.
    @Test func vaultsCountBySubscriptionNotByName() {
        let id = UUID()
        func vault(_ name: String, subscription: String) -> DestinationModel {
            DestinationModel(
                repositoryID: nil,
                target: .azureKeyVault(vaultName: name, tenantID: Self.example),
                stage: nil,
                sortOrder: 0,
                subscription: KeyVaultSubscriptionModel(id: id, name: subscription),
                createdAt: .distantPast,
                updatedAt: .distantPast
            )
        }
        let rows = AzureTenantRowModel.rows(
            vaults: [vault("kv-a", subscription: "Example Production"), vault("kv-b", subscription: "Example Prod")],
            listed: [],
            requirement: .notInstalled
        )
        #expect(rows.first?.subline == "Example Prod · 2 vaults")
    }

    @Test func countsReadInEnglish() {
        #expect(AzureAccountsCopy.subscriptionVaults("Example Production", count: 1) == "Example Production · 1 vault")
        #expect(AzureAccountsCopy.otherVaults(2) == "2 other vaults")
        #expect(AzureAccountsCopy.added(vaults: 2, secrets: 5) == "Added 2 vaults with 5 secrets.")
        #expect(AzureAccountsCopy.notRead(["kv-a", "kv-b"]) == "Could not read kv-a and kv-b.")
    }
}
