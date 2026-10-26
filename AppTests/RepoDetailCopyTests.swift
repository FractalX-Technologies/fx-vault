import AppKit
import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Copy and paste (v0.4.0; any repository and linked since v0.4.1): ⌘C keeps the items in the
/// app and puts only their names on the pasteboard, ⌘V in another scope or repository copies
/// them as linked copies (asking "Replace or keep?" for names that scope has), Copy To does the
/// same from a menu, and text copied since still opens the .env import.
@MainActor
@Suite("Repository detail copy and paste")
struct RepoDetailCopyTests {
    static let otherValue = "FXV_FIXTURE_OTHER_VALUE"
    static let newValue = "FXV_FIXTURE_NEW_VALUE"

    @MainActor
    struct Fixture {
        let harness: TestHarness
        let recorder = ActionRecorder()
        let repositoryID: RepoID
        let viewModel: RepoDetailViewModel
        let staging: ConfigScope
        let production: ConfigScope

        /// The imported repository: repository level `API_TOKEN` (synced, with a value) and
        /// `NEW_A` (added); environments production (`DEPLOY_KEY` without a value) and staging.
        init() async throws {
            let (harness, id) = try await EditorFixtures.importedHarness()
            self.harness = harness
            repositoryID = id
            let secret = try await EditorFixtures.item(harness, id, named: "API_TOKEN")
            try harness.data.config.fillValue(secret.id, value: SecretBytes(utf8: EditorFixtures.secretValue), pushOnNextSync: false)
            try harness.data.config.addItem(repositoryID: id, scope: .repository, kind: .secret, name: "NEW_A", value: SecretBytes(utf8: EditorFixtures.secretValue))
            let scopes = try harness.data.config.scopes(repositoryID: id)
            staging = try #require(scopes.first { $0.environment?.name == "staging" }).scope
            production = try #require(scopes.first { $0.environment?.name == "production" }).scope
            let recorder = recorder
            viewModel = RepoDetailViewModel(
                repositoryID: id,
                dependencies: harness.dependencies(recorder: recorder),
                repository: { harness.repository(id) },
                scopeSummary: { scope in
                    try? harness.data.config.scopes(repositoryID: id).first { $0.scope == scope }
                }
            )
            viewModel.kind = .secret
        }

        func waitForRows(_ names: Set<String>) async -> Bool {
            let model = viewModel
            return await TestFixtures.eventually { Set(model.rows.map(\.name)) == names }
        }

        func select(_ names: Set<String>) {
            viewModel.selection = Set(viewModel.rows.filter { names.contains($0.name) }.map(\.id))
        }

        func value(_ name: String, in scope: ConfigScope) async throws -> String? {
            let item = try await EditorFixtures.item(harness, repositoryID, named: name, scope: scope)
            let value = try harness.data.config.reveal(item.id)
            defer { value.wipe() }
            return value.utf8String()
        }
    }

    @Test func copySelectionThenPasteInAnotherScope() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        #expect(await fixture.waitForRows(["API_TOKEN", "NEW_A"]))
        fixture.select(["API_TOKEN", "NEW_A"])

        model.copySelection()
        #expect(fixture.harness.container.clipboard.itemsToPaste?.names == ["API_TOKEN", "NEW_A"])
        #expect(fixture.harness.pasteboardString == "API_TOKEN\nNEW_A", "names only, never values")
        #expect(model.notice == "Copied 2 items. Open another scope or repository and paste them with ⌘V: the copies stay linked to these items.")

        model.select(scope: fixture.staging)
        await model.handlePaste([NSItemProvider(object: "API_TOKEN\nNEW_A" as NSString)])

        #expect(await fixture.waitForRows(["API_TOKEN", "NEW_A"]))
        #expect(model.rows.allSatisfy { $0.status == .added })
        #expect(try await fixture.value("API_TOKEN", in: fixture.staging) == EditorFixtures.secretValue)
        #expect(model.notice == "Copied 2 items to staging.")
        #expect(fixture.recorder.presented.isEmpty, "no .env import")
        #expect(await TestFixtures.eventually { model.rows.allSatisfy { $0.isLinked && $0.linkCount == 2 } })
    }

    @Test func pastingIntoAScopeWithTheSameNamesAsksReplaceOrKeep() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        try fixture.harness.data.config.addItem(
            repositoryID: fixture.repositoryID,
            scope: fixture.staging,
            kind: .secret,
            name: "API_TOKEN",
            value: SecretBytes(utf8: RepoDetailCopyTests.otherValue)
        )
        #expect(await fixture.waitForRows(["API_TOKEN", "NEW_A"]))
        fixture.select(["API_TOKEN"])
        let targets = model.copyTargets
        #expect(targets.map(\.title) == ["production", "staging"])
        let staging = try #require(targets.first { $0.scope == fixture.staging })

        model.copy(model.selectedRows, to: staging)
        let request = try #require(model.pendingCopy)
        #expect(request.conflicts == ["API_TOKEN"])
        #expect(request.title == "staging already has API_TOKEN")
        #expect(request.replaceTitle == "Replace Its Value")

        model.confirmCopy(replacing: false)
        #expect(model.notice == "Nothing was copied to staging. Kept 1 that staging already had.")
        #expect(try await fixture.value("API_TOKEN", in: fixture.staging) == RepoDetailCopyTests.otherValue)

        model.copy(model.selectedRows, to: staging)
        model.confirmCopy(replacing: true)
        #expect(model.notice == "Copied 1 item to staging.")
        #expect(try await fixture.value("API_TOKEN", in: fixture.staging) == EditorFixtures.secretValue)
    }

    @Test func textCopiedSinceStillOpensTheImport() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        #expect(await fixture.waitForRows(["API_TOKEN", "NEW_A"]))
        fixture.select(["NEW_A"])
        model.copySelection()
        let text = "REGION=eu"
        fixture.harness.pasteboard.clearContents()
        fixture.harness.pasteboard.setString(text, forType: .string)

        model.select(scope: fixture.staging)
        await model.handlePaste([NSItemProvider(object: text as NSString)])

        guard case .envImport(let context) = try #require(fixture.recorder.presented.last) else {
            Issue.record("expected the .env import")
            return
        }
        #expect(context.place == .scope(repositoryID: fixture.repositoryID, scope: fixture.staging))
    }

    @Test func secretsWithoutAValueAreNotCopied() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        model.select(scope: fixture.production)
        #expect(await fixture.waitForRows(["DEPLOY_KEY"]))
        fixture.select(["DEPLOY_KEY"])
        let staging = try #require(model.copyTargets.first { $0.scope == fixture.staging })

        model.copy(model.selectedRows, to: staging)

        #expect(model.pendingCopy == nil)
        #expect(model.notice == "Nothing was copied to staging. Not copied, no value in FX Vault (GitHub never returns secret values): DEPLOY_KEY. Fill them first.")
    }

    @Test func pastingIntoTheSameScopeOnlyExplains() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        #expect(await fixture.waitForRows(["API_TOKEN", "NEW_A"]))
        fixture.select(["NEW_A"])
        model.copySelection()

        await model.handlePaste([NSItemProvider(object: "NEW_A" as NSString)])

        #expect(model.notice == "These items are already in this scope. Open another scope or repository to paste them.")
        #expect(model.rows.count == 2)
    }

    @Test func lockForgetsTheCopiedItems() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        #expect(await fixture.waitForRows(["API_TOKEN", "NEW_A"]))
        fixture.select(["NEW_A"])
        model.copySelection()
        #expect(fixture.harness.container.clipboard.itemsToPaste != nil)

        fixture.harness.app.lock(trigger: .manual)
        #expect(fixture.harness.container.clipboard.itemsToPaste == nil)
        #expect(model.pendingCopy == nil)
    }

    // MARK: - Another repository and linked copies (v0.4.1)

    @Test func pasteIntoAnotherRepository() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        #expect(await fixture.waitForRows(["API_TOKEN", "NEW_A"]))
        let otherID = try await fixture.harness.stageRepository(name: "other-repo")
        let other = Self.detail(fixture, otherID)
        fixture.select(["API_TOKEN"])
        model.copySelection()

        await other.handlePaste([NSItemProvider(object: "API_TOKEN" as NSString)])

        #expect(other.notice == "Copied 1 item to Repository.")
        #expect(await TestFixtures.eventually { other.rows.map(\.name) == ["API_TOKEN"] && other.rows.first?.isLinked == true })
        let copy = try await EditorFixtures.item(fixture.harness, otherID, named: "API_TOKEN")
        let value = try fixture.harness.data.config.reveal(copy.id)
        defer { value.wipe() }
        #expect(value.utf8String() == EditorFixtures.secretValue)
        #expect(await TestFixtures.eventually { model.rows.first { $0.name == "API_TOKEN" }?.linkCount == 2 })
    }

    @Test func copyToAnotherRepositoryOpensTheList() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        #expect(await fixture.waitForRows(["API_TOKEN", "NEW_A"]))
        fixture.select(["NEW_A"])

        model.copyToOtherRepository(model.selectedRows)

        guard case .copyToRepository(let context) = try #require(fixture.recorder.presented.last) else {
            Issue.record("expected Copy to Another Repository")
            return
        }
        #expect(context.itemIDs == model.selectedRows.map(\.id))
        #expect(context.source == .scope(repositoryID: fixture.repositoryID, scope: .repository))
    }

    @Test func linkedCopiesPopoverListsOpensAndUnlinks() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        #expect(await fixture.waitForRows(["API_TOKEN", "NEW_A"]))
        fixture.select(["NEW_A"])
        let staging = try #require(model.copyTargets.first { $0.scope == fixture.staging })
        model.copy(model.selectedRows, to: staging)
        #expect(await TestFixtures.eventually { model.rows.first { $0.name == "NEW_A" }?.isLinked == true })
        let row = try #require(model.rows.first { $0.name == "NEW_A" })

        model.showLinkedCopies(of: row)
        #expect(model.linkedPopoverRowID == row.id)
        let copy = try #require(model.linkedCopies.first)
        #expect(model.linkedCopies.count == 1)
        #expect(copy.itemPlace == .scope(repositoryID: fixture.repositoryID, scope: fixture.staging))
        #expect(copy.comparison == .same)
        #expect(copy.placeDetail(itemName: "NEW_A") == "staging · user-a")
        #expect(copy.placeDetail(itemName: "OTHER") == "staging · NEW_A · user-a")
        #expect(copy.placePath == "\(TestFixtures.owner) › \(TestFixtures.repoName) › staging")
        #expect(copy.placePath(itemName: "NEW_A") == copy.placePath)
        #expect(copy.placePath(itemName: "OTHER") == "\(TestFixtures.owner) › \(TestFixtures.repoName) › staging · NEW_A")
        #expect(copy.blockedNote == nil, "an editable copy has a checkbox, not a note")

        model.openLinkedCopy(copy)
        #expect(model.linkedPopoverRowID == nil)
        #expect(model.linkedCopies.isEmpty)
        #expect(fixture.recorder.openings == [ActionRecorder.OpenedScope(repositoryID: fixture.repositoryID, scope: fixture.staging)])

        model.unlink(row)
        #expect(model.notice == "NEW_A is no longer linked. The copies stay where they are.")
        #expect(await TestFixtures.eventually { model.rows.first { $0.name == "NEW_A" }?.isLinked == false })
    }

    private static func detail(_ fixture: Fixture, _ id: RepoID) -> RepoDetailViewModel {
        let harness = fixture.harness
        let model = RepoDetailViewModel(
            repositoryID: id,
            dependencies: harness.dependencies(recorder: fixture.recorder),
            repository: { harness.repository(id) },
            scopeSummary: { scope in
                try? harness.data.config.scopes(repositoryID: id).first { $0.scope == scope }
            }
        )
        model.kind = .secret
        return model
    }
}
