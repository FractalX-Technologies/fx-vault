import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Actions on several selected rows of the detail table (v0.4.0): one confirmation and one
/// transaction for a Delete of several rows, Revert and Push on Next Sync only for the rows they
/// apply to, nothing in a read-only scope.
@MainActor
@Suite("Repository detail selection")
struct RepoDetailSelectionTests {
    @MainActor
    struct Fixture {
        let harness: TestHarness
        let repositoryID: RepoID
        let viewModel: RepoDetailViewModel

        /// The imported repository: `API_TOKEN` synced with a value ("already matches GitHub"),
        /// plus `NEW_A` and `NEW_B` added locally (never synced).
        init(permission: String = "ADMIN") async throws {
            let (harness, id) = try await EditorFixtures.importedHarness(permission: permission)
            self.harness = harness
            repositoryID = id
            if permission == "ADMIN" {
                let secret = try await EditorFixtures.item(harness, id, named: "API_TOKEN")
                try harness.data.config.fillValue(secret.id, value: SecretBytes(utf8: EditorFixtures.secretValue), pushOnNextSync: false)
                for name in ["NEW_A", "NEW_B"] {
                    try harness.data.config.addItem(repositoryID: id, scope: .repository, kind: .secret, name: name, value: SecretBytes(utf8: EditorFixtures.secretValue))
                }
            }
            viewModel = RepoDetailViewModel(
                repositoryID: id,
                dependencies: harness.dependencies(recorder: ActionRecorder()),
                repository: { harness.repository(id) },
                scopeSummary: { scope in
                    try? harness.data.config.scopes(repositoryID: id).first { $0.scope == scope }
                }
            )
            viewModel.kind = .secret
        }

        func rows(count: Int) async throws -> [ConfigRowModel] {
            let model = viewModel
            #expect(await TestFixtures.eventually { model.rows.count == count })
            return model.rows
        }

        func select(_ names: Set<String>) {
            viewModel.selection = Set(viewModel.rows.filter { names.contains($0.name) }.map(\.id))
        }

        func status(_ name: String) -> ConfigSyncStatus? {
            viewModel.rows.first { $0.name == name }?.status
        }
    }

    @Test func deletingSeveralRowsAsksOnceAndDeletesThemTogether() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        _ = try await fixture.rows(count: 3)
        fixture.select(["API_TOKEN", "NEW_A", "NEW_B"])
        #expect(model.selectedRows.map(\.name) == ["API_TOKEN", "NEW_A", "NEW_B"])

        model.requestDeletion(of: model.selectedRows)
        let deletion = try #require(model.pendingDeletion)
        #expect(deletion.syncedRows.map(\.name) == ["API_TOKEN"])
        #expect(deletion.unsyncedCount == 2)
        #expect(deletion.title == "Delete 3 items?")
        #expect(deletion.confirmTitle == "Delete 3 Items")
        #expect(deletion.message.hasPrefix("API_TOKEN is deleted on GitHub by the next Sync"))
        #expect(deletion.message.hasSuffix("The 2 never synced are removed now."))
        #expect(fixture.status("API_TOKEN") == .synced, "nothing changes before the confirmation")

        model.confirmDeletion()
        #expect(await TestFixtures.eventually { model.rows.map(\.name) == ["API_TOKEN"] })
        #expect(fixture.status("API_TOKEN") == .deleted)
        #expect(model.selection.isEmpty)
        #expect(model.alert == nil)
        #expect(model.notice?.hasPrefix("Deleted 3 items. The next Sync deletes 1 of them on GitHub") == true)
        #expect(try EditorFixtures.pendingCount(fixture.harness, fixture.repositoryID) == 1)
    }

    @Test func rowsNeverSyncedAreRemovedWithoutAsking() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        _ = try await fixture.rows(count: 3)
        fixture.select(["NEW_A", "NEW_B"])

        model.deleteSelection()
        #expect(model.pendingDeletion == nil)
        #expect(await TestFixtures.eventually { model.rows.map(\.name) == ["API_TOKEN"] })
        #expect(model.notice == "Removed 2 items that were never synced.")
    }

    @Test func pushAndRevertActOnlyOnTheRowsTheyApplyTo() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        _ = try await fixture.rows(count: 3)
        fixture.select(["API_TOKEN", "NEW_A"])
        let actions = ConfigSelectionActionsModel(rows: model.selectedRows)
        #expect(actions.pushable.map(\.name) == ["API_TOKEN"])
        #expect(actions.revertible.isEmpty)
        #expect(actions.deletable.count == 2)

        model.pushOnNextSync(model.selectedRows)
        #expect(await TestFixtures.eventually { fixture.status("API_TOKEN") == .willPush })
        #expect(fixture.status("NEW_A") == .added)
        #expect(model.notice == "The next Sync pushes 1 secret to GitHub. Revert cancels it.")
        #expect(model.selection.isEmpty)

        fixture.select(["API_TOKEN", "NEW_A", "NEW_B"])
        model.revert(model.selectedRows)
        #expect(await TestFixtures.eventually { fixture.status("API_TOKEN") == .synced })
        #expect(fixture.status("NEW_A") == .added, "Revert never removes an added row")
        #expect(fixture.status("NEW_B") == .added)
        #expect(model.notice == "Reverted 1 item to what GitHub has.")
    }

    @Test func aReadOnlyScopeDeletesNothing() async throws {
        let fixture = try await Fixture(permission: "READ")
        let model = fixture.viewModel
        let rows = try await fixture.rows(count: 1)
        #expect(!model.canEdit)
        model.selection = Set(rows.map(\.id))

        model.requestDeletion(of: rows)
        model.pushOnNextSync(rows)
        #expect(model.pendingDeletion == nil)
        #expect(fixture.status("API_TOKEN") == .synced)
        #expect(model.alert == nil)
    }

    @Test func deletionNamesShowThreeThenACount() {
        #expect(ConfigDeletionModel.names(["A", "B"]) == "A and B")
        #expect(ConfigDeletionModel.names(["A", "B", "C"]) == "A, B, and C")
        #expect(ConfigDeletionModel.names(["A", "B", "C", "D", "E"]) == "A, B, C and 2 more")
    }
}
