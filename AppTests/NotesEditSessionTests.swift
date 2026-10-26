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
        #expect(model.acceptsFileDrops)

        model.beginNotesEdit(at: nil)
        #expect(!model.acceptsFileDrops)
        model.dropFile(key)
        #expect(fixture.recorder.presented.isEmpty)

        model.notesEdit?.cancel()
        model.dropFile(key)
        #expect(fixture.recorder.presented.count == 1)
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
