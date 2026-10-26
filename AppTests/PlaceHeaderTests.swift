import DestinationKit
import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// A place's header and ⋯ More (1.0 D6c3; boards Main2-Repository, Main2-Actions, Folder-View,
/// KV-Place): the "kind · parent · counts" line, New Secret / New Variable and Copy To.
@MainActor
@Suite("Place header")
struct PlaceHeaderTests {
    @Test func countsAreInflectedAndSayWhatLacksAValue() {
        #expect(PlaceCopy.counts(secrets: 6, variables: 2, withoutValue: 1) == "6 secrets · 2 variables · 1 without value")
        #expect(PlaceCopy.counts(secrets: 1, variables: 1) == "1 secret · 1 variable")
        #expect(PlaceCopy.counts(secrets: 32, variables: nil) == "32 secrets")
        #expect(PlaceCopy.subline([PlaceCopy.environment, nil, "", "api-service"]) == "Environment · api-service")
    }

    @Test func aRepositoryScopeSaysWhatItIsWhereAndHowMany() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let model = fixture.viewModel
        #expect(await TestFixtures.eventually { model.items.count == 2 })
        #expect(model.headerTitle == TestFixtures.repoName)
        #expect(model.headerSubline == "Repository · \(TestFixtures.owner) · Private · created by the next Sync · 1 secret · 1 variable")

        let environmentID = try fixture.harness.data.config.createEnvironment(in: fixture.repositoryID, name: "production")
        model.select(scope: .environment(environmentID))
        #expect(await TestFixtures.eventually { model.items.isEmpty })
        #expect(model.headerTitle == "production")
        #expect(model.headerSubline == "Environment · \(TestFixtures.repoName) · 0 secrets · 0 variables")
    }

    @Test func anEnvironmentCountsItsSecretsWithoutAValue() async throws {
        let fixture = try await RepoDetailCopyTests.Fixture()
        let model = fixture.viewModel
        model.select(scope: fixture.production)
        #expect(await TestFixtures.eventually { model.items.contains { $0.name == "DEPLOY_KEY" } })
        #expect(model.headerTitle == "production")
        #expect(model.headerSubline.hasPrefix("Environment · "))
        #expect(model.headerSubline.hasSuffix(" · 1 without value"), "DEPLOY_KEY has no value")
    }

    @Test func newVariableOpensTheVariablesTabAndItsEditor() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let model = fixture.viewModel
        _ = try await fixture.secretRow()
        model.add(.variable)
        #expect(model.kind == .variable, "the new row shows when the editor closes")
        #expect(fixture.recorder.presented == [
            .itemEditor(ItemEditorContext(repositoryID: fixture.repositoryID, scope: .repository, mode: .add(.variable))),
        ])
    }

    @Test func copyToTakesTheSelectionOrTheWholeTab() async throws {
        let fixture = try await FolderViewModelTests.Fixture()
        let model = fixture.folder
        #expect(await fixture.waitForFolderRows(["FIREBASE_API_KEY"]))
        #expect(model.placeCopyRows.map(\.name) == ["FIREBASE_API_KEY"], "nothing selected: the open tab")
        #expect(model.subline == "Folder · never sent anywhere by itself · 1 secret · 1 variable")

        let repository = fixture.repository.viewModel
        #expect(await TestFixtures.eventually { !repository.rows.isEmpty })
        repository.kind = .secret
        let rows = repository.rows
        let first = try #require(rows.first)
        repository.selection = [first.id]
        #expect(repository.placeCopyRows.map(\.id) == [first.id], "a selection: only it")
    }

    /// A pending deletion is neither copied by Copy To nor deleted again by Delete Selected….
    @Test func aPendingDeletionIsLeftOutOfCopyToAndDeleteSelected() async throws {
        let fixture = try await RepoDetailSelectionTests.Fixture()
        let model = fixture.viewModel
        _ = try await fixture.rows(count: 3)
        #expect(!model.canDeleteSelection, "nothing selected")
        fixture.select(["API_TOKEN"])
        #expect(model.canDeleteSelection)
        model.deleteSelection()
        model.confirmDeletion()
        #expect(await TestFixtures.eventually { fixture.status("API_TOKEN") == .deleted })

        #expect(model.placeCopyRows.map(\.name) == ["NEW_A", "NEW_B"], "the tab without its pending deletion")
        fixture.select(["API_TOKEN"])
        #expect(model.placeCopyRows.isEmpty)
        #expect(!model.canDeleteSelection, "only a pending deletion is selected")
    }

    /// Board KV-Place: "Key Vault · counts" (the subscription arrives with 1g); a runtime
    /// destination adds Runtime and its stage, or "No stage".
    @Test func aKeyVaultSaysWhatItIsAndARuntimeOneItsStage() async throws {
        let fixture = try await DestinationViewModelTests.Fixture()
        let staged = try fixture.detail(try fixture.addVault(stage: "production"))
        #expect(staged.subline == "Key Vault · Runtime · production · 0 secrets")
        let unstagedID = try fixture.destinations.createDestination(
            repositoryID: fixture.repositoryID,
            target: .azureKeyVault(vaultName: "kv-sample-dev", tenantID: nil),
            stage: nil
        )
        #expect(try fixture.detail(unstagedID).subline == "Key Vault · Runtime · No stage · 0 secrets")

        let ownID = try fixture.destinations.createDestination(
            repositoryID: nil,
            target: .azureKeyVault(vaultName: "kv-example-shared", tenantID: nil),
            stage: nil
        )
        let own = try fixture.detail(ownID)
        try fixture.destinations.addItem(destinationID: ownID, kind: .secret, name: "DATABASE_URL", value: SecretBytes(utf8: "FXV_FIXTURE_SECRET"))
        #expect(await TestFixtures.eventually { own.subline == "Key Vault · 1 secret" })
    }

    /// A Key Vault read from Azure: Refresh says "Refreshing…" until `az` answers, and Delete
    /// Selected… needs a selected secret that is not already a pending deletion.
    @Test func aKeyVaultShowsItsRefreshAndKeepsDeleteForLiveSecrets() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: MainViewModelTests.ready)
        try harness.installFakeAZ()
        harness.transport.stubKeyVault("kv-example-prod", secrets: ["DATABASE-URL": "postgres://example"])
        let destinations = harness.data.destinations
        let id = try destinations.createDestination(
            repositoryID: nil,
            target: .azureKeyVault(vaultName: "kv-example-prod", tenantID: nil),
            stage: nil
        )
        _ = try await harness.data.destinationSync.importRemote(destinationID: id)
        let model = DestinationDetailViewModel(
            destination: try #require(try destinations.destination(id)),
            dependencies: harness.dependencies(recorder: ActionRecorder())
        ) {
            try? destinations.destination(id)
        }
        #expect(await TestFixtures.eventually { model.rows.count == 1 })
        let row = try #require(model.rows.first)

        model.refreshNow()
        #expect(model.isRefreshing, "the header shows Refreshing… at once")
        #expect(PlaceCopy.refreshing == "Refreshing…")
        #expect(await TestFixtures.eventually { !model.isRefreshing })

        #expect(!model.canDeleteSelection, "nothing selected")
        model.selection = [row.id]
        #expect(model.canDeleteSelection)
        try destinations.deleteItems([row.id])
        #expect(await TestFixtures.eventually { model.rows.first?.isDeleted == true }, "an imported secret waits for Sync")
        #expect(!model.canDeleteSelection, "only a pending deletion is selected")
    }
}
