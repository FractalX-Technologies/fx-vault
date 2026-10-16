import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Copy To › Another Repository… (v0.4.1): the vault's repositories by account, search, the
/// chosen repository's scopes, "Replace or keep?", the outcome and Show; and "Also update linked
/// copies" in the item editor.
@MainActor
@Suite("Copy to another repository and linked updates")
struct CopyToRepositoryViewModelTests {
    @MainActor
    struct Fixture {
        let harness: TestHarness
        let recorder = ActionRecorder()
        let sourceID: RepoID
        let otherID: RepoID
        let apiToken: ConfigItemModel

        /// The imported repository (`API_TOKEN` with a value at repository level) and a staged
        /// repository `other-repo` with a `staging` environment.
        init() async throws {
            let (harness, id) = try await EditorFixtures.importedHarness()
            self.harness = harness
            sourceID = id
            let secret = try await EditorFixtures.item(harness, id, named: "API_TOKEN")
            try harness.data.config.fillValue(secret.id, value: SecretBytes(utf8: EditorFixtures.secretValue), pushOnNextSync: false)
            apiToken = secret
            otherID = try await harness.stageRepository(
                name: "other-repo",
                environments: [RepoCreationEnvironmentDraftModel(name: "staging")]
            )
        }

        func viewModel() async -> CopyToRepositoryViewModel {
            let model = CopyToRepositoryViewModel(
                context: CopyToRepositoryContext(itemIDs: [apiToken.id], sourceRepositoryID: sourceID, sourceScope: .repository),
                dependencies: harness.dependencies(recorder: recorder)
            )
            await model.load()
            return model
        }

        func value(_ name: String, in repositoryID: RepoID, scope: ConfigScope = .repository) async throws -> String? {
            let item = try await EditorFixtures.item(harness, repositoryID, named: name, scope: scope)
            let value = try harness.data.config.reveal(item.id)
            defer { value.wipe() }
            return value.utf8String()
        }
    }

    @Test func listsRepositoriesByAccountAndFiltersThem() async throws {
        let fixture = try await Fixture()
        let model = await fixture.viewModel()

        #expect(model.isLoaded)
        #expect(model.subtitle == "Copies API_TOKEN. The copy stays linked to it.")
        #expect(model.sections.map(\.accountLogin) == [TestFixtures.account])
        #expect(model.sections.first?.repositories.map(\.name) == [TestFixtures.repoName, "other-repo"])

        model.searchText = "OTHER"
        #expect(model.sections.first?.repositories.map(\.name) == ["other-repo"])
        model.searchText = "nothing-matches"
        #expect(model.sections.isEmpty)
    }

    @Test func theSourceScopeIsLeftOutOfItsOwnRepository() async throws {
        let fixture = try await Fixture()
        let model = await fixture.viewModel()
        let source = try #require(model.repositories.first { $0.id == fixture.sourceID })

        model.select(source)

        #expect(model.targets.map(\.scopeTitle) == ["production", "staging"])
        #expect(model.targets.allSatisfy { $0.target.isEditable && $0.readOnlyReason == nil })
    }

    @Test func copiesIntoTheChosenScopeAndShowsIt() async throws {
        let fixture = try await Fixture()
        let model = await fixture.viewModel()
        let other = try #require(model.repositories.first { $0.id == fixture.otherID })
        #expect(!model.canCopy)

        model.select(other)
        #expect(model.targets.map(\.scopeTitle) == ["Repository", "staging"])
        let staging = try #require(model.targets.last)
        model.selectedTargetID = staging.id
        #expect(model.canCopy)
        model.copy()

        #expect(model.result == ItemCopyResultModel(added: 1))
        #expect(model.resultNotice == "Copied 1 item to \(TestFixtures.owner)/other-repo · staging.")
        #expect(!model.canCopy)
        #expect(try await fixture.value("API_TOKEN", in: fixture.otherID, scope: staging.target.scope) == EditorFixtures.secretValue)

        model.showTarget()
        #expect(fixture.recorder.openings == [ActionRecorder.OpenedScope(repositoryID: fixture.otherID, scope: staging.target.scope)])
    }

    @Test func aNameTheScopeHasAsksReplaceOrKeep() async throws {
        let fixture = try await Fixture()
        try fixture.harness.data.config.addItem(
            repositoryID: fixture.otherID,
            scope: .repository,
            kind: .secret,
            name: "API_TOKEN",
            value: SecretBytes(utf8: RepoDetailCopyTests.otherValue)
        )
        let model = await fixture.viewModel()
        let other = try #require(model.repositories.first { $0.id == fixture.otherID })
        model.select(other)
        model.selectedTargetID = model.targets.first?.id

        model.copy()
        let request = try #require(model.pendingCopy)
        #expect(request.conflicts == ["API_TOKEN"])
        #expect(model.result == nil)

        model.confirm(replacing: true)
        #expect(model.pendingCopy == nil)
        #expect(model.result == ItemCopyResultModel(replaced: 1))
        #expect(try await fixture.value("API_TOKEN", in: fixture.otherID) == EditorFixtures.secretValue)
    }

    // MARK: - Item editor: Also update linked copies (L4)

    @Test func editingALinkedItemUpdatesTheCheckedCopies() async throws {
        let fixture = try await Fixture()
        let config = fixture.harness.data.config
        try config.copyItems([fixture.apiToken.id], to: .repository, repositoryID: fixture.otherID, conflicts: .keep)
        let staging = try #require(try config.scopes(repositoryID: fixture.otherID).first { $0.environment?.name == "staging" }).scope
        try config.copyItems([fixture.apiToken.id], to: staging, repositoryID: fixture.otherID, conflicts: .keep)
        let inStaging = try await EditorFixtures.item(fixture.harness, fixture.otherID, named: "API_TOKEN", scope: staging)
        try config.editValue(inStaging.id, value: SecretBytes(utf8: RepoDetailCopyTests.otherValue))

        let editor = ItemEditorViewModel(
            context: ItemEditorContext(repositoryID: fixture.sourceID, scope: .repository, mode: .edit(fixture.apiToken.id)),
            dependencies: fixture.harness.dependencies(recorder: fixture.recorder)
        )
        await editor.load()
        #expect(editor.linkedCopies.count == 2)
        #expect(!editor.offersLinkedUpdate, "only once a new value is entered")
        let same = try #require(editor.linkedCopies.first { $0.comparison == .same })
        let differs = try #require(editor.linkedCopies.first { $0.comparison == .differs })
        #expect(editor.linkedSelection == [same.itemID], "the copy that still has the current value")

        editor.value = RepoDetailCopyTests.newValue
        #expect(editor.offersLinkedUpdate)
        #expect(editor.save())

        #expect(try await fixture.value("API_TOKEN", in: fixture.otherID) == RepoDetailCopyTests.newValue)
        #expect(try await fixture.value("API_TOKEN", in: fixture.otherID, scope: staging) == RepoDetailCopyTests.otherValue)
        #expect(differs.itemID == inStaging.id)
    }

    @Test func uncheckingEveryCopyUpdatesOnlyTheItem() async throws {
        let fixture = try await Fixture()
        let config = fixture.harness.data.config
        try config.copyItems([fixture.apiToken.id], to: .repository, repositoryID: fixture.otherID, conflicts: .keep)
        let editor = ItemEditorViewModel(
            context: ItemEditorContext(repositoryID: fixture.sourceID, scope: .repository, mode: .edit(fixture.apiToken.id)),
            dependencies: fixture.harness.dependencies(recorder: fixture.recorder)
        )
        await editor.load()
        let copy = try #require(editor.linkedCopies.first)

        editor.value = RepoDetailCopyTests.newValue
        editor.setLinkedCopy(copy.itemID, included: false)
        #expect(editor.save())

        #expect(try await fixture.value("API_TOKEN", in: fixture.sourceID) == RepoDetailCopyTests.newValue)
        #expect(try await fixture.value("API_TOKEN", in: fixture.otherID) == EditorFixtures.secretValue)
    }
}
