import AppKit
import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Copy and paste between scopes of one repository (v0.4.0): ⌘C keeps the items in the app and
/// puts only their names on the pasteboard, ⌘V in another scope copies them (asking "Replace or
/// keep?" for names that scope has), Copy To… does the same from a menu, and text copied since
/// still opens the .env import.
@MainActor
@Suite("Repository detail copy and paste")
struct RepoDetailCopyTests {
    static let otherValue = "FXV_FIXTURE_OTHER_VALUE"

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
        #expect(model.copiedItems?.names == ["API_TOKEN", "NEW_A"])
        #expect(fixture.harness.pasteboardString == "API_TOKEN\nNEW_A", "names only, never values")
        #expect(model.notice == "Copied 2 items. Open another scope of this repository and paste them with ⌘V.")

        model.select(scope: fixture.staging)
        await model.handlePaste([NSItemProvider(object: "API_TOKEN\nNEW_A" as NSString)])

        #expect(await fixture.waitForRows(["API_TOKEN", "NEW_A"]))
        #expect(model.rows.allSatisfy { $0.status == .added })
        #expect(try await fixture.value("API_TOKEN", in: fixture.staging) == EditorFixtures.secretValue)
        #expect(model.notice == "Copied 2 items to staging.")
        #expect(fixture.recorder.presented.isEmpty, "no .env import")
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
        #expect(context.scope == fixture.staging)
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

        #expect(model.notice == "These items are already in this scope. Open another scope of this repository to paste them.")
        #expect(model.rows.count == 2)
    }

    @Test func lockForgetsTheCopiedItems() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        #expect(await fixture.waitForRows(["API_TOKEN", "NEW_A"]))
        fixture.select(["NEW_A"])
        model.copySelection()
        #expect(model.copiedItems != nil)

        fixture.harness.app.lock(trigger: .manual)
        #expect(model.copiedItems == nil)
        #expect(model.pendingCopy == nil)
    }
}
