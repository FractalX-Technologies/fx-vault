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
}
