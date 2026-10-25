import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// The scopes column over a staged repository in an in-memory vault.
@MainActor
@Suite("Scope list")
struct ScopeListViewModelTests {
    @MainActor
    struct Fixture {
        let harness: TestHarness
        let recorder = ActionRecorder()
        let repositoryID: RepoID
        let viewModel: ScopeListViewModel

        init() async throws {
            harness = try await TestHarness(vault: .unlocked)
            let id = try await harness.stageRepository(
                items: [TestFixtures.item(.variable, "BASE_URL", "https://example.com")],
                environments: [
                    RepoCreationEnvironmentDraftModel(
                        name: "staging",
                        items: [TestFixtures.item(.secret, "API_TOKEN", "FXV_FIXTURE_SECRET")]
                    ),
                ]
            )
            repositoryID = id
            let harness = harness
            viewModel = ScopeListViewModel(
                repositoryID: id,
                dependencies: harness.dependencies(recorder: recorder)
            ) {
                try? harness.data.config.changeSet(repositoryID: id)?.repository
            }
        }
    }

    @Test func listsRepositoryThenEnvironments() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        #expect(await TestFixtures.eventually { model.scopes.count == 2 })
        #expect(model.scopes.map(\.title) == ["Repository", "staging"])
        #expect(model.selectedScopeID == ScopeListViewModel.repositoryScopeID)
        #expect(model.selectedScope?.scope == .repository)
        let staging = model.scopes[1]
        #expect(staging.hasPendingChanges)
        #expect(staging.valueMissingCount == 0)
        #expect(model.canCreateEnvironment)
        #expect(model.canEdit(staging))
        #expect(!model.canEdit(model.scopes[0]))
    }

    @Test func actionsPresentFeatureSheets() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        #expect(await TestFixtures.eventually { model.scopes.count == 2 })
        let staging = model.scopes[1]
        let environmentID = try #require(staging.environment?.id)
        let context = EnvironmentContext(repositoryID: fixture.repositoryID, environmentID: environmentID)

        model.rename(staging)
        model.duplicate(staging)
        model.openSettings(staging)
        model.exportEnv(staging)
        model.share(staging)
        #expect(fixture.recorder.presented == [
            .renameEnvironment(context),
            .duplicateEnvironment(context),
            .environmentSettings(context),
            .envExport(EnvExportContext(repositoryID: fixture.repositoryID, scope: .environment(environmentID))),
            .shareExport(ShareExportContext(selection: .environment(environmentID))),
        ])
    }

    @Test func deletingAnUnsyncedEnvironmentRemovesItAndReselectsRepository() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        #expect(await TestFixtures.eventually { model.scopes.count == 2 })
        var selections = 0
        model.onSelectionChange = { selections += 1 }
        model.selectedScopeID = model.scopes[1].id
        #expect(selections == 1)

        model.requestDeletion(model.scopes[1])
        #expect(model.pendingDeletion != nil)
        model.confirmDeletion()
        #expect(model.alert == nil)
        #expect(await TestFixtures.eventually { model.scopes.count == 1 })
        #expect(model.selectedScopeID == ScopeListViewModel.repositoryScopeID)
    }

    /// v0.4.0 (Bryan: some accounts lack access to some things): every environment action needs
    /// admin and is offered disabled otherwise; Export and Share follow the values only.
    @Test(arguments: [("ADMIN", true), ("WRITE", false), ("READ", false)])
    func environmentActionsFollowThePermission(permission: String, isAdmin: Bool) async throws {
        let (harness, id) = try await EditorFixtures.importedHarness(permission: permission)
        let recorder = ActionRecorder()
        let viewModel = ScopeListViewModel(repositoryID: id, dependencies: harness.dependencies(recorder: recorder)) {
            harness.repository(id)
        }
        #expect(await TestFixtures.eventually { viewModel.environments.count == 2 })
        let production = try #require(viewModel.environments.first { $0.environment?.name == "production" })

        #expect(viewModel.canCreateEnvironment == isAdmin)
        #expect(viewModel.canEdit(production) == isAdmin)
        #expect(viewModel.canExport(production), "values can be exported whatever the permission")

        viewModel.requestDeletion(production)
        viewModel.rename(production)
        #expect(recorder.presented.count == (isAdmin ? 1 : 0))
        #expect((viewModel.pendingDeletion != nil) == isAdmin)
    }
}
