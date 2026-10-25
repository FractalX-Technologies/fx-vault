import AppKit
import DestinationKit
import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Destinations in the app (v0.8.0, tasks/todo.md R7–R10): the scope column's Overview and
/// RUNTIME rows, the destination detail, Add Destination, the Overview matrix and the
/// destination part of the Sync sheet.
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
            try destinations.createDestination(repositoryID: repositoryID, target: DestinationViewModelTests.vault, stage: stage)
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
        #expect(scopes.rowIDs.first == ScopeListViewModel.repositoryScopeID)
        #expect(scopes.rowIDs.last == ScopeListViewModel.selectionID(of: id))

        scopes.select(destination: id)
        #expect(scopes.selectedDestination?.id == id)
        #expect(scopes.selectedScope == nil)
        scopes.select(scope: .repository)
        #expect(scopes.selectedScope?.scope == .repository)
        #expect(scopes.selectedDestination == nil)

        // A destination asked for before it exists is selected when it appears.
        let later = try fixture.destinations.createDestination(
            repositoryID: fixture.repositoryID,
            target: .azureKeyVault(vaultName: "kv-sample-stg", tenantID: nil),
            stage: "staging"
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

    // MARK: - Add Destination

    @Test func addDestinationValidatesTheFormAndKeepsTheDestinationWhenTheImportFails() async throws {
        let fixture = try await Fixture()
        let model = AddDestinationViewModel(context: AddDestinationContext(repositoryID: fixture.repositoryID), dependencies: fixture.dependencies)
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

    // MARK: - Supabase and Vercel removed (1.0)

    @Test func theRetiredDestinationsNoticeShowsOnceThenClearsTheVault() {
        var stored = ["owner-a/web · Supabase abcdefghijklmnopqrst", "owner-a/web · Vercel example-web (production)"]
        var clears = 0
        let notice = RetiredDestinationsNotice(load: { stored }, dismiss: { clears += 1; stored = [] })
        #expect(notice.labels.isEmpty, "nothing shows before the window appears unlocked")
        notice.load()
        #expect(notice.labels == ["owner-a/web · Supabase abcdefghijklmnopqrst", "owner-a/web · Vercel example-web (production)"])
        let message = DestinationCopy.retiredMessage(notice.labels)
        #expect(message.contains("owner-a/web · Supabase abcdefghijklmnopqrst"))
        #expect(message.contains("nothing was deleted in Supabase or Vercel"))

        // OK and the alert's binding both dismiss: the vault is cleared once.
        notice.dismiss()
        notice.dismiss()
        #expect(notice.labels.isEmpty)
        #expect(clears == 1)
        notice.load()
        #expect(notice.labels.isEmpty, "the next unlock shows nothing")
    }

    @Test func aFailingReadShowsNoNotice() {
        struct Failure: Error {}
        let notice = RetiredDestinationsNotice(load: { throw Failure() }, dismiss: {})
        notice.load()
        #expect(notice.labels.isEmpty)
    }

    // MARK: - Sync sheet

    @Test func theSyncSummaryAddsDestinationSectionsBlocksAndDeletions() throws {
        let repositoryID = RepoID()
        let destination = DestinationModel(
            repositoryID: repositoryID,
            target: Self.vault,
            stage: "production",
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
                blocked: [DestinationBlockedChangeModel(change: missing, reason: .valueMissing)]
            ),
        ])
        let merged = DestinationSyncPresentation.merge([], with: [review]) { id in
            RepoModel(
                id: id,
                accountLogin: "owner-a",
                githubID: nil,
                ownerLogin: "owner-a",
                ownerType: .user,
                name: "repo-a",
                visibility: .private,
                hasAdmin: true,
                hasPush: true,
                origin: .imported,
                importedAt: Date(timeIntervalSince1970: 0)
            )
        }
        let repository = try #require(merged.first)
        #expect(repository.fullName == "owner-a/repo-a")
        #expect(repository.place.name == "repo-a")
        #expect(repository.pendingCount == 2)
        #expect(repository.scopes.first?.details == ["~ DATABASE_URL as DATABASE-URL", "− OLD_KEY as OLD-KEY"])
        #expect(repository.scopes.first?.lines.map(\.symbol) == [.modified, .deleted])
        // The vault's card holds its lines and its blocked change.
        let card = try #require(repository.cards.first)
        #expect(repository.cards.count == 1)
        #expect(card.place.name == destination.title)
        #expect(card.lines.map(\.detail) == ["secret · as DATABASE-URL", "secret · as OLD-KEY · deleted in Key Vault"])
        #expect(card.blocked.count == 1)
        #expect(repository.blocked.first?.fix == .fillValue(ItemEditorContext(destinationID: destination.id, mode: .fill(missing.itemID))))

        let deletions = DestinationSyncPresentation.mergeDeletions([], with: [review]) { _ in "owner-a/repo-a" }
        #expect(deletions.first?.items.count == 1)

        let result = DestinationRunResultModel(outcomes: [push.id: .done, delete.id: .failed(.azNotSignedIn)])
        let rows = DestinationSyncPresentation.resultRows([result], reviews: [review])
        #expect(rows[.succeeded]?.count == 1)
        #expect(rows[.failed]?.first?.fix == .runInTerminal(command: "az login"))
    }
}
