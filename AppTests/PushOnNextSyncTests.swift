import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// v0.1.2 "Push on Next Sync" from the detail table's context menu: offered for synced secrets
/// with a value, shown as "Will push", counted by the Sync button, undone by Revert.
@MainActor
@Suite("Push on Next Sync")
struct PushOnNextSyncTests {
    @MainActor
    struct Fixture {
        let harness: TestHarness
        let repositoryID: RepoID
        let viewModel: RepoDetailViewModel

        /// The imported repository with `API_TOKEN` filled as "already matches GitHub".
        init() async throws {
            let (harness, id) = try await EditorFixtures.importedHarness()
            self.harness = harness
            repositoryID = id
            let secret = try await EditorFixtures.item(harness, id, named: "API_TOKEN")
            try harness.data.config.fillValue(secret.id, value: SecretBytes(utf8: EditorFixtures.secretValue), pushOnNextSync: false)
            viewModel = RepoDetailViewModel(
                repositoryID: id,
                dependencies: harness.dependencies(recorder: ActionRecorder()),
                repository: { harness.repository(id) },
                scopeSummary: { scope in
                    try? harness.data.config.scopes(repositoryID: id).first { $0.scope == scope }
                }
            )
        }

        func row(_ name: String, kind: ConfigKind, status: ConfigSyncStatus) async throws -> ConfigRowModel {
            let model = viewModel
            model.kind = kind
            #expect(await TestFixtures.eventually {
                model.rows.contains { $0.name == name && $0.status == status }
            })
            return try #require(model.rows.first { $0.name == name })
        }
    }

    @Test func markingASyncedSecretMakesItPendingAndEnablesSync() async throws {
        let fixture = try await Fixture()
        let app = fixture.harness.app
        let main = app.makeMainViewModel()
        #expect(await TestFixtures.eventually { app.pendingChangeCount == 0 })
        #expect(!main.canSync, "nothing to push yet")

        let secret = try await fixture.row("API_TOKEN", kind: .secret, status: .synced)
        #expect(secret.canPushOnNextSync)
        #expect(!secret.canRevert)

        fixture.viewModel.pushOnNextSync(secret)

        let marked = try await fixture.row("API_TOKEN", kind: .secret, status: .willPush)
        #expect(marked.status.localizedTitle == "Will push")
        #expect(!marked.canPushOnNextSync, "already marked")
        #expect(marked.canRevert)
        #expect(fixture.viewModel.alert == nil)
        #expect(fixture.viewModel.notice?.contains("API_TOKEN") == true)
        #expect(try EditorFixtures.pendingCount(fixture.harness, fixture.repositoryID) == 1)
        #expect(await TestFixtures.eventually { app.pendingChangeCount == 1 })
        #expect(main.canSync)

        let review = try #require(try fixture.harness.data.config.changeSet(repositoryID: fixture.repositoryID))
        guard case .setItem(let set) = try #require(review.changes.first).operation else {
            Issue.record("expected a secret set")
            return
        }
        #expect(set.reason == .forcePushed && set.name == "API_TOKEN")
    }

    @Test func revertCancelsThePush() async throws {
        let fixture = try await Fixture()
        let secret = try await fixture.row("API_TOKEN", kind: .secret, status: .synced)
        fixture.viewModel.pushOnNextSync(secret)
        let marked = try await fixture.row("API_TOKEN", kind: .secret, status: .willPush)

        fixture.viewModel.revert(marked)

        let reverted = try await fixture.row("API_TOKEN", kind: .secret, status: .synced)
        #expect(reverted.canPushOnNextSync)
        #expect(try EditorFixtures.pendingCount(fixture.harness, fixture.repositoryID) == 0)
        #expect(await TestFixtures.eventually { fixture.harness.app.pendingChangeCount == 0 })
    }

    @Test func notOfferedForVariablesOrValueMissingSecrets() async throws {
        let fixture = try await Fixture()
        let variable = try await fixture.row("BASE_URL", kind: .variable, status: .synced)
        #expect(!variable.canPushOnNextSync, "variables are compared by value")
        fixture.viewModel.pushOnNextSync(variable)
        #expect(try EditorFixtures.pendingCount(fixture.harness, fixture.repositoryID) == 0)

        let scopes = try fixture.harness.data.config.scopes(repositoryID: fixture.repositoryID)
        let production = try #require(scopes.first { $0.environment?.name == "production" })
        fixture.viewModel.select(scope: production.scope)
        let missing = try await fixture.row("DEPLOY_KEY", kind: .secret, status: .synced)
        #expect(!missing.hasValue)
        #expect(!missing.canPushOnNextSync, "fill it instead")
    }
}
