import AppKit
import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Folders in the app (v0.7.0, tasks/todo.md F1–F6): the folder detail (table, reveal, add and
/// edit through the item editor, deletion), copy and paste between folders and repositories with
/// links, `.env` import and export of a folder, New Folder… and Rename….
@MainActor
@Suite("Folders in the app")
struct FolderViewModelTests {
    @MainActor
    struct Fixture {
        let repository: RepoDetailCopyTests.Fixture
        let recorder = ActionRecorder()
        let folderID: FolderID
        let folder: FolderDetailViewModel

        /// The repository fixture plus "Mobile App" with FIREBASE_API_KEY (secret) and API_URL
        /// (variable).
        init() async throws {
            repository = try await RepoDetailCopyTests.Fixture()
            let folders = repository.harness.data.folders
            folderID = try folders.createFolder(named: "Mobile App")
            try folders.addItem(folderID: folderID, kind: .secret, name: "FIREBASE_API_KEY", value: SecretBytes(utf8: EditorFixtures.secretValue))
            try folders.addItem(folderID: folderID, kind: .variable, name: "API_URL", value: SecretBytes(utf8: "https://api.example.invalid"))
            let id = folderID
            folder = FolderDetailViewModel(
                folderID: id,
                dependencies: repository.harness.dependencies(recorder: recorder)
            ) { [folders] in
                (try? folders.folders())?.first { $0.id == id }
            }
            folder.kind = .secret
        }

        var harness: TestHarness {
            repository.harness
        }

        func waitForFolderRows(_ names: Set<String>) async -> Bool {
            let model = folder
            return await TestFixtures.eventually { Set(model.rows.map(\.name)) == names }
        }

        func folderValue(_ name: String, in folderID: FolderID) throws -> String? {
            let item = try #require(try harness.data.folders.items(folderID: folderID).first { $0.name == name })
            let value = try harness.data.folders.reveal(item.id)
            defer { value.wipe() }
            return value.utf8String()
        }
    }

    // MARK: - Folder detail

    @Test func theFolderTableHasNoStatusAndRevealsLikeARepository() async throws {
        let fixture = try await Fixture()
        let model = fixture.folder
        #expect(await fixture.waitForFolderRows(["FIREBASE_API_KEY"]))
        #expect(!model.showsSyncStatus)
        #expect(model.canEdit)
        #expect(model.count(of: .secret) == 1 && model.count(of: .variable) == 1)
        let row = try #require(model.rows.first)
        #expect(model.display(for: row) == .masked)

        model.toggleReveal(row.id)
        await TableRevealTests.confirm(model.notesReveal)
        #expect(model.display(for: row) == .revealed(EditorFixtures.secretValue))
        model.remaskAll()
        #expect(model.display(for: row) == .masked)

        model.kind = .variable
        let variable = try #require(model.rows.first)
        #expect(await TestFixtures.eventually { model.display(for: variable) == .plain("https://api.example.invalid") })
        model.vaultDidLock()
        #expect(model.display(for: variable) == .masked)
    }

    @Test func addAndEditOpenTheEditorOnTheFolder() async throws {
        let fixture = try await Fixture()
        let model = fixture.folder
        #expect(await fixture.waitForFolderRows(["FIREBASE_API_KEY"]))

        model.add()
        model.edit(try #require(model.rows.first))
        #expect(fixture.recorder.presented == [
            .itemEditor(ItemEditorContext(folderID: fixture.folderID, mode: .add(.secret))),
            .itemEditor(ItemEditorContext(folderID: fixture.folderID, mode: .edit(try #require(model.rows.first).id))),
        ])
    }

    @Test func deletingAsksFirstAndRemovesAtOnce() async throws {
        let fixture = try await Fixture()
        let model = fixture.folder
        #expect(await fixture.waitForFolderRows(["FIREBASE_API_KEY"]))
        model.selection = Set(model.rows.map(\.id))

        model.deleteSelection()
        #expect(model.pendingDeletion?.map(\.name) == ["FIREBASE_API_KEY"])
        #expect(model.deletionSheet?.title == "Delete 1 secret from Mobile App?")
        model.confirmDeletion()
        #expect(await fixture.waitForFolderRows([]))
        #expect(model.selection.isEmpty)
        #expect(try fixture.harness.data.folders.items(folderID: fixture.folderID).map(\.name) == ["API_URL"])
    }

    /// The selection bar counts the folder's own rows, as a repository's: one row and an id whose
    /// row is gone (deleted elsewhere) show none.
    @Test func theSelectionBarNeedsTwoOfTheFoldersRows() async throws {
        let fixture = try await Fixture()
        let model = fixture.folder
        #expect(await fixture.waitForFolderRows(["FIREBASE_API_KEY"]))
        let row = try #require(model.rows.first)

        model.selection = [row.id, ConfigItemID()]

        #expect(model.selectedRows.map(\.name) == ["FIREBASE_API_KEY"])
        #expect(!model.showsSelectionActions)
    }

    // MARK: - Copy and paste (F5, F6)

    @Test func aRepositoryItemPastedIntoTheFolderIsLinked() async throws {
        let fixture = try await Fixture()
        let repository = fixture.repository
        #expect(await repository.waitForRows(["API_TOKEN", "NEW_A"]))
        repository.select(["API_TOKEN"])
        repository.viewModel.copySelection()

        await fixture.folder.handlePaste([NSItemProvider(object: "API_TOKEN" as NSString)])

        #expect(await fixture.waitForFolderRows(["API_TOKEN", "FIREBASE_API_KEY"]))
        #expect(fixture.folder.notice == "Copied 1 item to Mobile App.")
        #expect(try fixture.folderValue("API_TOKEN", in: fixture.folderID) == EditorFixtures.secretValue)
        #expect(await TestFixtures.eventually { fixture.folder.rows.first { $0.name == "API_TOKEN" }?.isLinked == true })
    }

    @Test func aFolderItemPastedIntoAScopeIsAPendingLinkedCopy() async throws {
        let fixture = try await Fixture()
        let model = fixture.folder
        #expect(await fixture.waitForFolderRows(["FIREBASE_API_KEY"]))
        model.selection = Set(model.rows.map(\.id))
        model.copySelection()
        #expect(fixture.harness.container.clipboard.itemsToPaste?.source == .folder(fixture.folderID))
        #expect(fixture.harness.pasteboardString == "FIREBASE_API_KEY", "names only, never values")

        let repository = fixture.repository
        repository.viewModel.select(scope: repository.staging)
        await repository.viewModel.handlePaste([NSItemProvider(object: "FIREBASE_API_KEY" as NSString)])

        #expect(try await repository.value("FIREBASE_API_KEY", in: repository.staging) == EditorFixtures.secretValue)
        let copy = try await EditorFixtures.item(fixture.harness, repository.repositoryID, named: "FIREBASE_API_KEY", scope: repository.staging)
        #expect(copy.syncStatus == .added)
        #expect(copy.isLinked || copy.linkID != nil)

        // Pasting into the folder it came from only explains.
        await model.handlePaste([NSItemProvider(object: "FIREBASE_API_KEY" as NSString)])
        #expect(model.notice == "These items are already in this folder. Open another folder, scope or repository to paste them.")
    }

    @Test func copyToListsFoldersAndAsksReplaceOrKeep() async throws {
        let fixture = try await Fixture()
        let folders = fixture.harness.data.folders
        let web = try folders.createFolder(named: "Web")
        try folders.addItem(folderID: web, kind: .secret, name: "FIREBASE_API_KEY", value: SecretBytes(utf8: "web-value"))
        let model = fixture.folder
        #expect(await fixture.waitForFolderRows(["FIREBASE_API_KEY"]))
        #expect(model.scopeCopyTargets.isEmpty)
        #expect(model.folderCopyTargets.map(\.title) == ["Web"])
        #expect(fixture.repository.viewModel.folderCopyTargets.map(\.title) == ["Mobile App", "Web"])

        let target = try #require(model.folderCopyTargets.first)
        model.copy(model.rows, to: target)
        #expect(model.pendingCopy?.conflicts == ["FIREBASE_API_KEY"])
        model.confirmCopy(replacing: true)
        #expect(model.pendingCopy == nil)
        #expect(try fixture.folderValue("FIREBASE_API_KEY", in: web) == EditorFixtures.secretValue)

        model.copyToOtherRepository(model.rows)
        guard case .copyToRepository(let context) = try #require(fixture.recorder.presented.last) else {
            Issue.record("expected Copy to Another Repository")
            return
        }
        #expect(context.source == .folder(fixture.folderID))
    }

    @Test func copyToAnotherRepositoryTakesFolderItems() async throws {
        let fixture = try await Fixture()
        let model = fixture.folder
        #expect(await fixture.waitForFolderRows(["FIREBASE_API_KEY"]))
        let copy = CopyToRepositoryViewModel(
            context: CopyToRepositoryContext(itemIDs: model.rows.map(\.id), source: .folder(fixture.folderID)),
            dependencies: fixture.harness.dependencies(recorder: fixture.recorder)
        )
        await copy.load()
        #expect(copy.itemNames == ["FIREBASE_API_KEY"])
        let repository = try #require(copy.repositories.first)
        copy.select(repository)
        copy.selectedTargetID = try #require(copy.targets.first { $0.scopeTitle == "staging" }).id
        copy.copy()
        #expect(copy.result == ItemCopyResultModel(added: 1))
        copy.showTarget()
        #expect(fixture.recorder.openings.last == ActionRecorder.OpenedScope(repositoryID: repository.id, scope: fixture.repository.staging))
    }

    @Test func folderActionsOpenTheirSheets() async throws {
        let fixture = try await Fixture()
        let model = fixture.folder
        model.pasteMultiple()
        model.exportEnv()
        model.shareAsFile()
        let presented = fixture.recorder.presented
        guard presented.count == 3, case .envImport(let importContext) = presented[0] else {
            Issue.record("expected the import sheet")
            return
        }
        #expect(importContext.place == .folder(fixture.folderID))
        #expect(importContext.defaultKind == .secret)
        #expect(presented[1] == .envExport(EnvExportContext(folderID: fixture.folderID)))
        #expect(presented[2] == .shareExport(ShareExportContext(selection: .folder(fixture.folderID))))
    }

    // MARK: - Item editor (F4, F6)

    @Test func theEditorAddsAndEditsAFolderItemAndUpdatesItsCopies() async throws {
        let fixture = try await Fixture()
        let harness = fixture.harness
        let dependencies = harness.dependencies(recorder: fixture.recorder)
        let add = ItemEditorViewModel(context: ItemEditorContext(folderID: fixture.folderID, mode: .add(.variable)), dependencies: dependencies)
        await add.load()
        #expect(add.subtitle == "In the folder Mobile App")
        #expect(add.isKindEditable)
        add.name = "app_env"
        add.value = "staging"
        #expect(add.save())
        #expect(try fixture.folderValue("APP_ENV", in: fixture.folderID) == "staging")

        // A copy in a repository, then a new value for the folder item updates it too.
        let source = try #require(try harness.data.folders.items(folderID: fixture.folderID).first { $0.name == "FIREBASE_API_KEY" })
        try harness.data.config.copyItems([source.id], to: .repository, repositoryID: fixture.repository.repositoryID, conflicts: .keep)
        let edit = ItemEditorViewModel(context: ItemEditorContext(folderID: fixture.folderID, mode: .edit(source.id)), dependencies: dependencies)
        await edit.load()
        #expect(edit.item?.isLinked == true)
        #expect(edit.isKindEditable, "a folder item is never on GitHub")
        #expect(edit.offersPushOnNextSync == false && edit.offersFillChoice == false)
        edit.value = "rotated-value"
        #expect(edit.offersLinkedUpdate)
        #expect(edit.linkedCopies.map(\.placeName) == [fixture.repository.harness.repository(fixture.repository.repositoryID)?.fullName ?? ""])
        #expect(edit.linkedSelection.count == 1)
        #expect(edit.save())
        #expect(try fixture.folderValue("FIREBASE_API_KEY", in: fixture.folderID) == "rotated-value")
        #expect(try await fixture.repository.value("FIREBASE_API_KEY", in: .repository) == "rotated-value")

        // A rename and a kind change in one save.
        let rename = ItemEditorViewModel(context: ItemEditorContext(folderID: fixture.folderID, mode: .edit(source.id)), dependencies: dependencies)
        await rename.load()
        rename.name = "FIREBASE_KEY"
        rename.kind = .variable
        #expect(rename.save() == false, "a secret becoming a variable asks first")
        #expect(rename.confirm())
        let renamed = try #require(try harness.data.folders.items(folderID: fixture.folderID).first { $0.id == source.id })
        #expect(renamed.name == "FIREBASE_KEY" && renamed.kind == .variable)
    }

    // MARK: - .env import and export

    @Test func envImportIntoAFolderIsFinal() async throws {
        let fixture = try await Fixture()
        let dependencies = fixture.harness.dependencies(recorder: fixture.recorder)
        let model = EnvImportViewModel(
            context: EnvImportContext(place: .folder(fixture.folderID), defaultKind: .variable, start: .pasteEditor),
            dependencies: dependencies
        )
        #expect(model.isFolder)
        #expect(model.repositoryID == nil)
        model.pastedText = "LOG_LEVEL=debug\nAPI_URL=https://other.example.invalid\n"
        model.parsePastedText()
        #expect(model.targetOption?.title == "Mobile App")
        #expect(model.conflictingRowIDs.count == 1)
        model.importRows()
        guard case .done(let result) = model.step else {
            Issue.record("expected the result")
            return
        }
        #expect(result.added == ["LOG_LEVEL"])
        #expect(!model.hasPendingChanges(result))
        #expect(try fixture.folderValue("LOG_LEVEL", in: fixture.folderID) == "debug")
    }

    @Test func envExportOfAFolderListsItsItems() async throws {
        let fixture = try await Fixture()
        let model = EnvExportViewModel(
            context: EnvExportContext(folderID: fixture.folderID),
            dependencies: fixture.harness.dependencies(recorder: fixture.recorder)
        )
        #expect(await TestFixtures.eventually { model.preview?.exportedNames == ["API_URL", "FIREBASE_API_KEY"] })
        #expect(model.repositoryName == "Mobile App")
        #expect(model.placeTitle == "Mobile App")
        #expect(model.unverifiedShareNames.isEmpty)
    }

    // MARK: - New Folder and Rename

    @Test func newFolderChecksTheNameAndOpensTheFolder() async throws {
        let fixture = try await Fixture()
        let dependencies = fixture.harness.dependencies(recorder: fixture.recorder)
        let model = FolderNameViewModel(context: FolderNameContext(mode: .create(itemIDs: [])), dependencies: dependencies)
        #expect(model.title == "New Folder")
        model.name = "mobile app"
        #expect(model.nameNote == .error(FolderCopy.nameTaken))
        #expect(!model.canSave)
        model.name = " Web"
        #expect(model.nameNote?.isError == true)
        model.name = "Web"
        #expect(model.save())
        let created = try #require(try fixture.harness.data.folders.folders().first { $0.name == "Web" })
        #expect(fixture.recorder.openedFolders == [created.id])

        let rename = FolderNameViewModel(context: FolderNameContext(mode: .rename(created.id)), dependencies: dependencies)
        #expect(rename.name == "Web")
        rename.name = "WEB"
        #expect(rename.nameNote == nil, "a case-only change of its own name")
        #expect(rename.save())
        #expect(try fixture.harness.data.folders.folders().map(\.name).contains("WEB"))
    }
}
