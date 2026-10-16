import AppKit
import DestinationKit
import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Destinations in the app (v0.8.0, tasks/todo.md R7–R10): the scope column's Overview and
/// RUNTIME rows, the destination detail, Add Destination, the Overview matrix, Settings ›
/// Destinations and the destination part of the Sync sheet.
@MainActor
@Suite("Destinations in the app")
struct DestinationViewModelTests {
    static let vault = DestinationTargetModel.azureKeyVault(vaultName: "kv-sample-prod", tenantID: nil)

    @MainActor
    struct Fixture {
        let harness: TestHarness
        let recorder = ActionRecorder()
        let repositoryID: RepoID

        init() async throws {
            let (harness, id) = try await EditorFixtures.importedHarness()
            self.harness = harness
            repositoryID = id
        }

        var dependencies: FeatureDependencies {
            harness.dependencies(recorder: recorder)
        }

        var destinations: DestinationRepository {
            harness.data.destinations
        }

        func addVault(stage: String? = "production") throws -> DestinationID {
            try destinations.createDestination(repositoryID: repositoryID, target: DestinationViewModelTests.vault, stage: stage, connectionID: nil)
        }

        func detail(_ id: DestinationID) throws -> DestinationDetailViewModel {
            let destinations = destinations
            let model = try #require(try destinations.destination(id))
            return DestinationDetailViewModel(destination: model, dependencies: dependencies) {
                try? destinations.destination(id)
            }
        }
    }

    // MARK: - Scope column

    @Test func theScopeColumnListsDestinationsAndSelectsThem() async throws {
        let fixture = try await Fixture()
        let scopes = ScopeListViewModel(repositoryID: fixture.repositoryID, dependencies: fixture.dependencies) {
            fixture.harness.repository(fixture.repositoryID)
        }
        #expect(await TestFixtures.eventually { !scopes.scopes.isEmpty })
        let id = try fixture.addVault()
        #expect(await TestFixtures.eventually { scopes.destinations.map(\.id) == [id] })
        #expect(scopes.rowIDs.first == ScopeListViewModel.overviewID)
        #expect(scopes.rowIDs.last == ScopeListViewModel.selectionID(of: id))

        scopes.select(destination: id)
        #expect(scopes.selectedDestination?.id == id)
        #expect(scopes.selectedScope == nil)
        scopes.selectOverview()
        #expect(scopes.isOverviewSelected)
        #expect(scopes.selectedDestination == nil)

        // A destination asked for before it exists is selected when it appears.
        let later = try fixture.destinations.createDestination(
            repositoryID: fixture.repositoryID,
            target: .azureKeyVault(vaultName: "kv-sample-stg", tenantID: nil),
            stage: "staging",
            connectionID: nil
        )
        scopes.select(destination: later)
        #expect(await TestFixtures.eventually { scopes.selectedDestination?.id == later })

        // Removing the selected destination falls back to Repository.
        scopes.requestRemoval(try #require(scopes.selectedDestination))
        scopes.confirmRemoval()
        #expect(await TestFixtures.eventually { scopes.selectedScopeID == ScopeListViewModel.repositoryScopeID })

        scopes.addDestination()
        #expect(fixture.recorder.presented.last == .addDestination(AddDestinationContext(repositoryID: fixture.repositoryID)))
    }

    // MARK: - Detail

    @Test func theDetailShowsPendingRowsAndRoutesEditsToTheEditor() async throws {
        let fixture = try await Fixture()
        let id = try fixture.addVault()
        let model = try fixture.detail(id)
        #expect(!model.holdsVariables)
        #expect(model.showsSyncStatus)
        try fixture.destinations.addItem(destinationID: id, kind: .variable, name: "API_URL", value: SecretBytes(utf8: "https://api.example.invalid"))
        #expect(await TestFixtures.eventually { model.rows.map(\.name) == ["API_URL"] })
        let row = try #require(model.rows.first)
        // A variable became a secret: Key Vault holds secrets only.
        #expect(row.kind == .secret)
        #expect(row.status == .added)
        #expect(model.display(for: row) == .masked)
        model.toggleReveal(row.id)
        #expect(model.display(for: row) == .revealed("https://api.example.invalid"))

        model.add()
        #expect(fixture.recorder.presented.last == .itemEditor(ItemEditorContext(destinationID: id, mode: .add(.secret))))
        model.edit(row)
        #expect(fixture.recorder.presented.last == .itemEditor(ItemEditorContext(destinationID: id, mode: .edit(row.id))))

        // A pending add is removed at once and can be reverted only before.
        model.requestDeletion(of: [row])
        model.confirmDeletion()
        #expect(await TestFixtures.eventually { model.rows.isEmpty })

        model.exportEnv()
        #expect(fixture.recorder.presented.last == .envExport(EnvExportContext(destinationID: id)))
        #expect(model.destinationCopyTargets.isEmpty)
        #expect(!model.scopeCopyTargets.isEmpty)
    }

    @Test func vercelPublicNamesCanBeMarkedAsPublic() async throws {
        let fixture = try await Fixture()
        let connection = try fixture.destinations.addConnection(provider: .vercel, label: "Vercel", token: SecretBytes(utf8: "t"), accountHint: nil)
        let id = try fixture.destinations.createDestination(
            repositoryID: fixture.repositoryID,
            target: .vercel(projectID: "prj_sample", projectName: "sample-web", teamID: nil, environment: .production),
            stage: "production",
            connectionID: connection
        )
        let model = try fixture.detail(id)
        #expect(model.holdsVariables)
        model.kind = .variable
        try fixture.destinations.addItem(destinationID: id, kind: .variable, name: "NEXT_PUBLIC_API_KEY", value: SecretBytes(utf8: "pk_live_sample"))
        #expect(await TestFixtures.eventually { model.rows.count == 1 })
        let row = try #require(model.rows.first)
        #expect(model.publicPrefix(of: row) == "NEXT_PUBLIC_")
        #expect(!model.isMarkedPublic(row))
        model.togglePublic(row)
        #expect(await TestFixtures.eventually { model.isMarkedPublic(row) })
    }

    // MARK: - Add Destination

    @Test func addDestinationValidatesTheFormAndKeepsTheDestinationWhenTheImportFails() async throws {
        let fixture = try await Fixture()
        let model = AddDestinationViewModel(context: AddDestinationContext(repositoryID: fixture.repositoryID), dependencies: fixture.dependencies)
        #expect(model.provider == .azureKeyVault)
        #expect(!model.canAdd)
        model.vaultName = "kv--bad"
        #expect(model.targetProblem != nil)
        #expect(!model.canAdd)
        model.vaultName = "kv-sample-prod"
        model.stage = "prod\u{202E}uction"
        #expect(model.stageProblem != nil)
        model.stage = "production"
        #expect(model.canAdd)

        model.add()
        // No az in the test sandbox: the destination is added and the import explains why it
        // could not list it.
        #expect(await TestFixtures.eventually {
            if case .done = model.phase { return true }
            return false
        })
        guard case .done(let added) = model.phase else { return }
        #expect(added.importError != nil)
        #expect(try fixture.destinations.destinations(repositoryID: fixture.repositoryID).map(\.target) == [Self.vault])
        model.openDestination()
        #expect(fixture.recorder.openedDestinations == [added.destinationID])
    }

    @Test func supabaseAndVercelNeedASavedConnection() async throws {
        let fixture = try await Fixture()
        let model = AddDestinationViewModel(context: AddDestinationContext(repositoryID: fixture.repositoryID), dependencies: fixture.dependencies)
        model.provider = .supabase
        #expect(model.connectionChoice == .newToken)
        model.projectRef = "abcdefghijklmnopqrst"
        #expect(!model.canAdd)
        let connection = try fixture.destinations.addConnection(provider: .supabase, label: "Supabase", token: SecretBytes(utf8: "sbp"), accountHint: nil)
        let again = AddDestinationViewModel(context: AddDestinationContext(repositoryID: fixture.repositoryID), dependencies: fixture.dependencies)
        again.provider = .supabase
        #expect(again.connectionChoice == .existing(connection))
        again.projectRef = "abcdefghijklmnopqrst"
        #expect(again.canAdd)
    }

    @Test func aManifestSuggestionPrefillsTheForm() async throws {
        let fixture = try await Fixture()
        let model = AddDestinationViewModel(
            context: AddDestinationContext(
                repositoryID: fixture.repositoryID,
                suggestion: AddDestinationSuggestion(location: .keyVault(vaultName: "kv-sample-stg"), stage: "staging")
            ),
            dependencies: fixture.dependencies
        )
        #expect(model.provider == .azureKeyVault)
        #expect(model.vaultName == "kv-sample-stg")
        #expect(model.stage == "staging")
    }

    // MARK: - Overview

    @Test func theOverviewBuildsTheStageMatrix() async throws {
        let fixture = try await Fixture()
        let id = try fixture.addVault()
        try fixture.destinations.addItem(destinationID: id, kind: .secret, name: "DATABASE_URL", value: SecretBytes(utf8: "postgres://a"))
        let model = StageOverviewViewModel(repositoryID: fixture.repositoryID, dependencies: fixture.dependencies) {
            fixture.harness.repository(fixture.repositoryID)
        }
        #expect(await TestFixtures.eventually { model.overview?.rows.contains { $0.name == "DATABASE_URL" } == true })
        #expect(model.stage == "production")
        #expect(model.stages.contains("staging"))
        #expect(model.destinationCount == 1)
        // gh is not ready in this harness: fxvault.yml is not read.
        #expect(model.manifestState == .unavailable)
        let row = try #require(model.overview?.rows.first { $0.name == "DATABASE_URL" })
        #expect(row.cells == [.notUsed, .willPush])
        model.open(row: row, column: 1)
        #expect(fixture.recorder.openedDestinations == [id])

        model.copyDraftManifest()
        #expect(model.notice == StageOverviewCopy.draftCopied)
        #expect(model.alert == nil)
    }

    // MARK: - Settings › Destinations

    @Test func settingsRenamesAndRemovesConnections() async throws {
        let fixture = try await Fixture()
        let settings = DestinationsSettingsViewModel(app: fixture.harness.app)
        let id = try fixture.destinations.addConnection(provider: .vercel, label: "Vercel", token: SecretBytes(utf8: "t"), accountHint: "user-a")
        #expect(await TestFixtures.eventually { settings.connections.map(\.id) == [id] })
        let connection = try #require(settings.connections.first)
        settings.startRename(connection)
        settings.renameText = "FractalX Vercel"
        settings.confirmRename()
        #expect(await TestFixtures.eventually { settings.connections.first?.label == "FractalX Vercel" })
        settings.addConnection()
        #expect(settings.editor?.mode == .add)
        #expect(settings.editor?.canSave == false)
        settings.cancelEditor()
        settings.requestRemoval(connection)
        settings.confirmRemoval()
        #expect(await TestFixtures.eventually { settings.connections.isEmpty })
        settings.vaultDidLock()
        #expect(settings.azureState == .unknown)
    }

    // MARK: - Sync sheet

    @Test func theSyncSummaryAddsDestinationSectionsBlocksAndDeletions() throws {
        let repositoryID = RepoID()
        let destination = DestinationModel(
            repositoryID: repositoryID,
            target: Self.vault,
            stage: "production",
            connectionID: nil,
            sortOrder: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
        let push = DestinationChangeModel(destinationID: destination.id, itemID: ConfigItemID(), name: "DATABASE_URL", remoteName: "DATABASE-URL", kind: .secret, operation: .update)
        let delete = DestinationChangeModel(destinationID: destination.id, itemID: ConfigItemID(), name: "OLD_KEY", remoteName: "OLD-KEY", kind: .secret, operation: .delete)
        let missing = DestinationChangeModel(destinationID: destination.id, itemID: ConfigItemID(), name: "NEW_KEY", remoteName: "NEW-KEY", kind: .secret, operation: .add)
        let review = DestinationReviewModel(repositoryID: repositoryID, sections: [
            DestinationReviewSectionModel(
                destination: destination,
                changes: [push, delete],
                blocked: [DestinationBlockedChangeModel(change: missing, reason: .valueMissing)],
                warnings: []
            ),
        ])
        let merged = DestinationSyncPresentation.merge([], with: [review]) { _ in "owner-a/repo-a" }
        let repository = try #require(merged.first)
        #expect(repository.fullName == "owner-a/repo-a")
        #expect(repository.pendingCount == 2)
        #expect(repository.scopes.first?.details == ["↑ DATABASE_URL as DATABASE-URL", "− OLD_KEY as OLD-KEY"])
        #expect(repository.blocked.first?.fix == .fillValue(ItemEditorContext(destinationID: destination.id, mode: .fill(missing.itemID))))

        let deletions = DestinationSyncPresentation.mergeDeletions([], with: [review]) { _ in "owner-a/repo-a" }
        #expect(deletions.first?.items.count == 1)

        let result = DestinationRunResultModel(outcomes: [push.id: .done, delete.id: .failed(.azNotSignedIn)])
        let rows = DestinationSyncPresentation.resultRows([result], reviews: [review])
        #expect(rows[.succeeded]?.count == 1)
        #expect(rows[.failed]?.first?.fix == .runInTerminal(command: "az login"))
    }
}
