import AppKit
import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// An edit of a place's notes from start to save (1.0 N2; boards Place-Edit, Place-Review):
/// revealed values hide first, Save writes pending changes through the place's repository, and
/// a lock, another scope or a read-only place leaves nothing to edit.
@MainActor
@Suite("Notes editing: the edit")
struct NotesEditSessionTests {
    static let token = NotesEditAnalysis.tokenCharacter

    static func editor(_ model: some NotesEditablePlaceModel) throws -> (NotesEditSession, NotesTextView) {
        let session = try #require(model.notesEdit)
        let view = NotesTextView(session: session)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        return (session, view)
    }

    static func replace(_ text: String, with replacement: String, in view: NSTextView) {
        view.setSelectedRange((view.string as NSString).range(of: text))
        if replacement.isEmpty {
            view.deleteBackward(nil)
        } else {
            NotesEditorTests.type(replacement, in: view)
        }
    }

    static func appendLine(_ text: String, in view: NSTextView) {
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        NotesEditorTests.type(text, in: view)
    }

    @Test func anEditHidesRevealedValuesAndSavesPendingChanges() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let model = fixture.viewModel
        let secret = try await fixture.secretRow()
        model.reveal(secret.id)
        #expect(model.isRevealed(secret.id))

        model.beginNotesEdit(at: 2)
        #expect(!model.isRevealed(secret.id))
        let (session, view) = try Self.editor(model)
        #expect(view.string == "# Secrets\nAPI_TOKEN = \(Self.token)\n\n# Variables\nBASE_URL = \(RepoDetailViewModelTests.variableValue)\n")

        Self.replace(RepoDetailViewModelTests.variableValue, with: "https://api.example.com", in: view)
        Self.appendLine("NEW_FLAG=on", in: view)
        Self.replace("API_TOKEN = \(Self.token)\n", with: "", in: view)
        #expect(session.changeCount == 3)

        session.requestReview()
        let review = try #require(session.review)
        #expect(review.sections.map(\.title) == [NotesEditCopy.added(1), NotesEditCopy.changed(1), NotesEditCopy.removed(1)])
        #expect(review.sections[1].rows.first?.detail == "\(RepoDetailViewModelTests.variableValue) → https://api.example.com")
        session.save()
        #expect(model.notesEdit == nil)
        #expect(session.isFinished)

        #expect(await TestFixtures.eventually {
            Set(model.rows(of: .variable).filter { !$0.isDeleted }.map(\.name)) == ["BASE_URL", "NEW_FLAG"]
                && model.count(of: .secret) == 0
        })
        let baseURL = try #require(model.rows(of: .variable).first { $0.name == "BASE_URL" })
        #expect(model.display(for: baseURL) == .plain("https://api.example.com"))
    }

    /// The repository's own API_TOKEN overrides the organization's: the organization's items stay
    /// read only under the editor, and removing API_TOKEN says the organization's value applies.
    @Test func anEditKeepsTheOrganizationsItemsOutOfTheText() async throws {
        let fixture = try await RepoDetailInheritedTests.fixture()
        try fixture.addOrganizationSecret("API_TOKEN")
        let model = fixture.model
        let owner = TestFixtures.owner
        #expect(await TestFixtures.eventually { model.notes.items.count == 4 })

        model.beginNotesEdit(at: nil)
        let (session, view) = try Self.editor(model)
        #expect(!view.string.contains("NPM_TOKEN") && !view.string.contains("REGION"))
        #expect(session.inherited?.lines.map(\.name) == ["NPM_TOKEN", "REGION"])
        #expect(NotesEditorTests.note(session, line: 1)?.text == "no value · overrides \(owner)")

        let text = view.string as NSString
        view.setSelectedRange(text.lineRange(for: text.range(of: "API_TOKEN")))
        view.deleteBackward(nil)
        session.requestReview()
        let removed = try #require(session.review?.sections.first)
        #expect(removed.title == NotesEditCopy.removed(1))
        #expect(removed.rows.first?.detail == NotesEditCopy.organizationValueApplies(owner))
    }

    /// Add file secret writes to the vault at once, around the edit: a file dropped while the
    /// notes are edited is refused, with no drop overlay.
    @Test func aFileDropWaitsForTheEditToEnd() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let model = fixture.viewModel
        let key = URL(fileURLWithPath: "/tmp/AuthKey.p8")
        #expect(model.acceptsOutsideEdits)

        model.beginNotesEdit(at: nil)
        #expect(!model.acceptsOutsideEdits)
        model.dropFile(key)
        #expect(fixture.recorder.presented.isEmpty)

        model.notesEdit?.cancel()
        model.dropFile(key)
        #expect(fixture.recorder.presented.count == 1)
    }

    /// The repository api-service selected in the main window, its scopes listed, and a Key Vault
    /// of its own in the sidebar.
    static func mainWindow() async throws -> (TestHarness, MainViewModel, RepoDetailViewModel, DestinationID) {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: MainViewModelTests.ready)
        let main = harness.app.makeMainViewModel()
        _ = try await harness.stageRepository(items: [TestFixtures.item(.secret, "API_TOKEN", "FXV_FIXTURE_SECRET")])
        let vaultID = try harness.data.destinations.createDestination(
            repositoryID: nil,
            target: .azureKeyVault(vaultName: "kv-example-prod", tenantID: nil),
            stage: nil
        )
        #expect(await TestFixtures.eventually { !main.sidebar.owners.isEmpty && !main.sidebar.keyVaults.isEmpty })
        main.sidebar.selectedRowID = try #require(main.sidebar.owners.flatMap(\.repos).first).id
        let detail = try #require(main.detail)
        #expect(await TestFixtures.eventually { main.scopeList?.selectedScope != nil })
        return (harness, main, detail, vaultID)
    }

    /// ⌘V of copied items or `.env` text and Import .env… write to the vault at once, around the
    /// edit: they wait for it to end, as a file drop does.
    @Test func pasteAndImportWaitForTheEditToEnd() async throws {
        let (_, main, detail, _) = try await Self.mainWindow()
        let providers = [NSItemProvider(object: "REGION=eu" as NSString)]
        #expect(main.canImportEnv)
        #expect(detail.validatePaste(providers)?.count == 1)

        detail.beginNotesEdit(at: nil)
        #expect(!main.canImportEnv)
        #expect(detail.validatePaste(providers) == nil)

        detail.notesEdit?.cancel()
        #expect(main.canImportEnv)
        #expect(detail.validatePaste(providers)?.count == 1)
    }

    /// With unsaved changes, another place or Table asks "Discard…?" first: Keep Editing puts the
    /// sidebar back, Discard ends the edit and goes on. Without changes the edit just ends.
    @Test func leavingAnEditWithChangesAsksFirst() async throws {
        let (_, main, detail, vaultID) = try await Self.mainWindow()
        let repository = main.sidebar.selectedRowID
        detail.beginNotesEdit(at: nil)
        let (session, view) = try Self.editor(detail)
        Self.appendLine("NEW_FLAG=on", in: view)
        #expect(session.changeCount == 1)

        main.sidebar.selectedKeyVaultID = vaultID
        #expect(main.discardRequest == NotesDiscardRequestModel(count: 1))
        #expect(main.destinationDetail == nil)
        main.keepEditingNotes()
        #expect(main.discardRequest == nil)
        #expect(main.sidebar.selectedRowID == repository)
        #expect(main.sidebar.selectedKeyVaultID == nil)
        #expect(main.detail === detail)
        #expect(detail.notesEdit === session)

        main.show(.table)
        #expect(main.discardRequest == NotesDiscardRequestModel(count: 1))
        #expect(main.placeViewMode == .notes)
        main.discardNotesEdit()
        #expect(main.placeViewMode == .table)
        #expect(session.isFinished)
        #expect(detail.notesEdit == nil)

        main.show(.notes)
        detail.beginNotesEdit(at: nil)
        let (again, againView) = try Self.editor(detail)
        Self.appendLine("OTHER_FLAG=on", in: againView)
        main.sidebar.selectedKeyVaultID = vaultID
        main.discardNotesEdit()
        #expect(again.isFinished)
        #expect(main.destinationDetail?.destinationID == vaultID)

        main.sidebar.selectedRowID = repository
        let next = try #require(main.detail)
        #expect(await TestFixtures.eventually { main.scopeList?.selectedScope != nil })
        next.beginNotesEdit(at: nil)
        main.sidebar.selectedKeyVaultID = vaultID
        #expect(main.discardRequest == nil, "nothing to lose")
        #expect(main.destinationDetail?.destinationID == vaultID)
    }

    /// Keep Editing leaves nothing asked for meanwhile: a ⌘K row in the edited place is selected
    /// only after Discard, and a scope asked for in another repository is not opened later.
    @Test func keepEditingLeavesNothingPending() async throws {
        let (harness, main, detail, _) = try await Self.mainWindow()
        let otherID = try await harness.stageRepository(name: "web-app", environments: [RepoCreationEnvironmentDraftModel(name: "staging")])
        let staging = try EditorFixtures.environment(harness, otherID, named: "staging")
        #expect(await TestFixtures.eventually { main.sidebar.owners.flatMap(\.repos).contains { $0.importedRepoID == otherID } })
        #expect(await TestFixtures.eventually { !detail.rows(of: .secret).isEmpty })
        let secret = try #require(detail.rows(of: .secret).first)
        let repositoryID = detail.repositoryID
        let jump = JumpItemModel(
            match: ItemNameMatchModel(id: secret.id, kind: .secret, name: secret.name, holder: .place(.scope(repositoryID: repositoryID, scope: .repository))),
            detail: "",
            target: .repositoryScope(repositoryID)
        )
        detail.beginNotesEdit(at: nil)
        let (_, view) = try Self.editor(detail)
        Self.appendLine("NEW_FLAG=on", in: view)

        main.jump(to: jump)
        #expect(main.discardRequest != nil)
        #expect(detail.selection.isEmpty, "nothing is selected before the answer")
        main.keepEditingNotes()
        #expect(detail.selection.isEmpty)
        #expect(main.placeViewMode == .notes)

        main.open(repositoryID: otherID, scope: .environment(staging.id))
        #expect(main.discardRequest != nil)
        main.keepEditingNotes()
        #expect(main.detail === detail)

        main.jump(to: jump)
        main.discardNotesEdit()
        #expect(main.placeViewMode == .table)
        #expect(detail.selection == [secret.id])

        main.sidebar.select(repositoryID: otherID)
        #expect(await TestFixtures.eventually { main.scopeList?.repositoryID == otherID && main.scopeList?.selectedScope != nil })
        #expect(main.scopeList?.selectedScope?.scope == .repository, "staging was asked for before Keep Editing")
    }

    @Test func lockingDropsTheEditAndItsValues() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let model = fixture.viewModel
        _ = try await fixture.secretRow()
        model.beginNotesEdit(at: nil)
        let (session, view) = try Self.editor(model)
        Self.appendLine("", in: view)
        let tokenID = try #require(NotesEditText.paragraphs(of: view.attributedString()).flatMap(\.tokens).first)
        try session.tokens.setValue(SecretBytes(utf8: "rotated"), for: tokenID)

        fixture.harness.app.lock(trigger: .manual)
        #expect(model.notesEdit == nil)
        #expect(session.tokens.model(tokenID) == nil, "the values are wiped")
    }

    @Test func anotherScopeDropsTheEdit() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let model = fixture.viewModel
        _ = try await fixture.secretRow()
        model.beginNotesEdit(at: nil)
        #expect(model.notesEdit != nil)

        try fixture.harness.data.config.createEnvironment(in: fixture.repositoryID, name: "production")
        let production = try EditorFixtures.environment(fixture.harness, fixture.repositoryID, named: "production")
        model.select(scope: .environment(production.id))
        #expect(model.notesEdit == nil)
    }

    @Test func anOrganizationsNotesStayReadOnly() async throws {
        let (harness, organization) = try await OrganizationEditingTests().imported()
        let detail = OrganizationDetailViewModel(
            organizationID: organization.id,
            dependencies: harness.dependencies(recorder: ActionRecorder()),
            organization: { organization },
            repositoryNames: { [] }
        )
        #expect(!((detail as AnyObject) is any NotesEditablePlaceModel))
    }

    @Test func aFolderSavesAtOnce() async throws {
        let fixture = try await FolderViewModelTests.Fixture()
        let model = fixture.folder
        #expect(await fixture.waitForFolderRows(["FIREBASE_API_KEY"]))
        model.beginNotesEdit(at: nil)
        let (session, view) = try Self.editor(model)
        Self.appendLine("NEW_URL=https://new.example.invalid", in: view)

        session.requestReview()
        #expect(session.review?.footer == NotesEditCopy.footerFolder)
        session.save()
        #expect(try fixture.folderValue("NEW_URL", in: fixture.folderID) == "https://new.example.invalid")
    }

    /// A Key Vault takes names as it writes them: `CACHE-URL` is saved as CACHE_URL.
    @Test func aKeyVaultSavesThroughItsDestination() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let destinations = harness.data.destinations
        let id = try destinations.createDestination(
            repositoryID: nil,
            target: .azureKeyVault(vaultName: "kv-example-prod", tenantID: nil),
            stage: nil
        )
        let model = DestinationDetailViewModel(
            destination: try #require(try destinations.destination(id)),
            dependencies: harness.dependencies(recorder: ActionRecorder())
        ) {
            try? destinations.destination(id)
        }
        model.beginNotesEdit(at: nil)
        let (session, view) = try Self.editor(model)
        #expect(view.string == "# Secrets\n")
        Self.appendLine("CACHE-URL=", in: view)
        let request = try #require(NotesEditText.paragraphs(of: view.attributedString()).flatMap(\.tokens).first)
        session.commitValue("redis://cache", for: request)
        #expect(NotesEditorTests.note(session, line: 1) == .info(NotesEditCopy.new(.secret)))

        session.requestReview()
        #expect(session.review?.footer == NotesEditCopy.footerKeyVault)
        session.save()
        #expect(try destinations.items(destinationID: id).map(\.name) == ["CACHE_URL"])
    }
}
