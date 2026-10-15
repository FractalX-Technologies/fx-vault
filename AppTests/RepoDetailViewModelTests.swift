import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// The detail column: rows, reveal and re-mask, copy, plaintext variables, row actions.
@MainActor
@Suite("Repository detail")
struct RepoDetailViewModelTests {
    static let secretValue = "FXV_FIXTURE_SECRET"
    static let variableValue = "https://example.com"

    @MainActor
    struct Fixture {
        let harness: TestHarness
        let recorder = ActionRecorder()
        let repositoryID: RepoID
        let viewModel: RepoDetailViewModel

        init(visibility: RepoVisibility = .private) async throws {
            harness = try await TestHarness(vault: .unlocked)
            let id = try await harness.stageRepository(
                visibility: visibility,
                items: [
                    TestFixtures.item(.secret, "API_TOKEN", RepoDetailViewModelTests.secretValue),
                    TestFixtures.item(.variable, "BASE_URL", RepoDetailViewModelTests.variableValue),
                ]
            )
            repositoryID = id
            let harness = harness
            viewModel = RepoDetailViewModel(
                repositoryID: id,
                dependencies: harness.dependencies(recorder: recorder),
                repository: { harness.repository(id) },
                scopeSummary: { scope in
                    try? harness.data.config.scopes(repositoryID: id).first { $0.scope == scope }
                }
            )
        }

        func secretRow() async throws -> ConfigRowModel {
            let model = viewModel
            #expect(await TestFixtures.eventually { model.items.count == 2 })
            model.kind = .secret
            return try #require(model.rows.first)
        }
    }

    @Test func rowsSplitByKindWithMaskedSecretsAndPlainVariables() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        let secret = try await fixture.secretRow()
        #expect(model.rows.map(\.name) == ["API_TOKEN"])
        #expect(secret.status == .added)
        #expect(model.display(for: secret) == .masked)
        #expect(model.count(of: .secret) == 1)

        model.kind = .variable
        let variable = try #require(model.rows.first)
        #expect(variable.name == "BASE_URL")
        #expect(model.display(for: variable) == .plain(Self.variableValue))
        #expect(model.canEdit)
        #expect(model.readOnlyReason == nil)
        #expect(!model.canClone)
    }

    @Test func revealMasksAgainAfterTheTimeout() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        let secret = try await fixture.secretRow()

        model.toggleReveal(secret.id)
        #expect(model.display(for: secret) == .revealed(Self.secretValue))
        await fixture.harness.clock.waitForSleepers(count: 1)
        fixture.harness.clock.advance(by: Timeouts.revealRemask)
        await model.remaskTasks[secret.id]?.value
        #expect(model.display(for: secret) == .masked)
    }

    @Test func revealMasksOnToggleResignActiveAndLock() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        let secret = try await fixture.secretRow()

        model.toggleReveal(secret.id)
        model.toggleReveal(secret.id)
        #expect(!model.isRevealed(secret.id))

        model.reveal(secret.id)
        model.remaskAll()
        #expect(!model.isRevealed(secret.id))
        #expect(model.remaskTasks.isEmpty)

        model.reveal(secret.id)
        fixture.harness.app.lock(trigger: .manual)
        #expect(!model.isRevealed(secret.id))
        #expect(model.variableValues.isEmpty)
    }

    @Test func copyGoesThroughTheClipboardManager() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        let secret = try await fixture.secretRow()

        model.copy(secret.id)
        #expect(fixture.harness.pasteboardString == Self.secretValue)
        #expect(fixture.harness.container.clipboard.ownsContents)
        #expect(model.notice?.contains("API_TOKEN") == true)
        #expect(!model.isRevealed(secret.id))

        // Cleared after the clipboard delay.
        await fixture.harness.clock.waitForSleepers(count: 1)
        fixture.harness.clock.advance(by: Timeouts.clipboardClear)
        await fixture.harness.container.clipboard.pendingClear?.value
        #expect(fixture.harness.pasteboardString == nil)
    }

    @Test func revealWhileLockedShowsAnError() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        let secret = try await fixture.secretRow()
        fixture.harness.vaultManager.lock()
        model.reveal(secret.id)
        #expect(!model.isRevealed(secret.id))
        #expect(model.alert != nil)
    }

    @Test func rowActionsPresentTheItemEditor() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        let secret = try await fixture.secretRow()

        model.add()
        model.edit(secret)
        model.move(secret)
        #expect(fixture.recorder.presented == [
            .itemEditor(ItemEditorContext(repositoryID: fixture.repositoryID, scope: .repository, mode: .add(.secret))),
            .itemEditor(ItemEditorContext(repositoryID: fixture.repositoryID, scope: .repository, mode: .edit(secret.id))),
            .itemEditor(ItemEditorContext(repositoryID: fixture.repositoryID, scope: .repository, mode: .move(secret.id))),
        ])
    }

    @Test func deletingAnUnsyncedItemNeedsNoConfirmation() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        let secret = try await fixture.secretRow()
        model.requestDeletion(secret)
        #expect(model.pendingDeletion == nil)
        #expect(await TestFixtures.eventually { model.count(of: .secret) == 0 })
        #expect(model.alert == nil)
    }

    @Test func planNoteOnlyForPrivateEnvironments() async throws {
        let fixture = try await Fixture(visibility: .public)
        #expect(!fixture.viewModel.showsPlanNote)
        let privateFixture = try await Fixture(visibility: .private)
        #expect(!privateFixture.viewModel.showsPlanNote)
        let environmentID = try privateFixture.harness.data.config.createEnvironment(in: privateFixture.repositoryID, name: "production")
        privateFixture.viewModel.select(scope: .environment(environmentID))
        #expect(privateFixture.viewModel.showsPlanNote)
        #expect(privateFixture.viewModel.branchPolicy == .all)
        privateFixture.viewModel.editBranchPolicy()
        #expect(privateFixture.recorder.presented == [
            .environmentSettings(EnvironmentContext(repositoryID: privateFixture.repositoryID, environmentID: environmentID)),
        ])
    }
}
