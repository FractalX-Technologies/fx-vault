import Foundation
import SyncEngine
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// A place's notes, read only (1.0 B9; boards Main2-Repository, KV-Place): numbered sections,
/// masked secrets, plaintext variables, the ○ / ● marks and each line's note.
@MainActor
@Suite("Place notes")
struct NotesDocumentTests {
    /// The notes as text: `2 ● API_TOKEN = •••• — no value`.
    static func lines(_ notes: NotesDocumentModel) -> [String] {
        notes.lines.map { line in
            switch line.content {
            case .heading(let title):
                "\(line.number) \(NotesCopy.heading(title))"
            case .blank:
                "\(line.number)"
            case .item(let item):
                "\(line.number) \(mark(item.mark))\(item.name) = \(value(item.value))\(item.note.map { " — \($0)" } ?? "")"
            }
        }
    }

    private static func mark(_ mark: NotesMarkModel?) -> String {
        switch mark {
        case .changedAtSource: "○ "
        case .pending: "● "
        case nil: ""
        }
    }

    private static func value(_ value: ConfigValueDisplayModel) -> String {
        switch value {
        case .masked: NotesCopy.maskToken
        case .revealed(let text): "[\(text)]"
        case .plain(let text): text
        case .missing: "∅"
        }
    }

    @Test func aScopesNotesMaskSecretsShowVariablesAndMarkWhatWaitsForSync() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let model = fixture.viewModel
        let expected = [
            "1 # Secrets · 1",
            "2 ● API_TOKEN = ••••",
            "3",
            "4 # Variables · 1",
            "5 ● BASE_URL = \(RepoDetailViewModelTests.variableValue)",
        ]
        #expect(await TestFixtures.eventually { Self.lines(model.notes) == expected })
        #expect(model.notes.items.map(\.canReveal) == [true, false])

        // The notes hold both kinds whatever the table's Secrets | Variables pill says.
        model.kind = .variable
        #expect(Self.lines(model.notes) == expected)
    }

    /// Plus an organization API_TOKEN (all) that the repository's own API_TOKEN overrides.
    @Test func aRepositoryListsWhatItsOrganizationGivesItReadOnly() async throws {
        let fixture = try await RepoDetailInheritedTests.fixture()
        try fixture.addOrganizationSecret("API_TOKEN")
        let model = fixture.model
        let owner = TestFixtures.owner
        #expect(await TestFixtures.eventually {
            Self.lines(model.notes) == [
                "1 # Secrets · 1",
                "2 API_TOKEN = ∅ — no value · overrides \(owner)",
                "3",
                "4 # Variables · 1",
                "5 BASE_URL = \(EditorFixtures.variableValue)",
                "6",
                "7 # From \(owner) · 2 · read only",
                "8 NPM_TOKEN = •••• — all repos",
                "9 REGION = eu-west — private and internal",
            ]
        })

        #expect(model.notes.items.map(\.isInherited) == [false, false, true, true], "drawn muted")

        // An organization secret has no value here: nothing to reveal.
        let npm = try #require(model.notes.items.first { $0.name == "NPM_TOKEN" })
        #expect(!npm.canReveal)
        model.notesReveal.ask(npm)
        #expect(model.notesReveal.request == nil)
    }

    @Test func aFolderNeverSyncsSoItsLinesHaveNoMarks() async throws {
        let fixture = try await FolderViewModelTests.Fixture()
        let model = fixture.folder
        #expect(await TestFixtures.eventually {
            Self.lines(model.notes) == [
                "1 # Secrets · 1",
                "2 FIREBASE_API_KEY = ••••",
                "3",
                "4 # Variables · 1",
                "5 API_URL = https://api.example.invalid",
            ]
        })
    }

    @Test func aKeyVaultHoldsSecretsOnly() async throws {
        let fixture = try await DestinationViewModelTests.Fixture()
        let id = try fixture.addVault()
        let model = try fixture.detail(id)
        try fixture.destinations.addItem(destinationID: id, kind: .variable, name: "API_URL", value: SecretBytes(utf8: "https://api.example.invalid"))
        #expect(await TestFixtures.eventually { Self.lines(model.notes) == ["1 # Secrets · 1", "2 ● API_URL = ••••"] })
        #expect(model.changedAtSourceTitle == "Changed in Key Vault")
    }

    /// Example-Org with a new API_TOKEN of its own; then GitHub changes NPM_TOKEN.
    @Test func anOrganizationsLinesSayWhoGetsThemAndRefreshMarksWhatChanged() async throws {
        let (harness, organization) = try await OrganizationEditingTests().imported()
        _ = try harness.data.organizationItems.addItem(
            organizationID: organization.id,
            kind: .secret,
            name: "API_TOKEN",
            value: SecretBytes(utf8: EditorFixtures.secretValue),
            access: .all
        )
        let detail = OrganizationDetailViewModel(
            organizationID: organization.id,
            dependencies: harness.dependencies(recorder: ActionRecorder()),
            organization: { organization },
            repositoryNames: { [] }
        )
        #expect(await TestFixtures.eventually {
            Self.lines(detail.notes) == [
                "1 # Secrets · 3",
                "2 ● API_TOKEN = •••• — all repos",
                "3 NPM_TOKEN = ∅ — no value · all repos",
                "4 STRIPE_KEY = ∅ — no value · selected · 3 repos",
                "5",
                "6 # Variables · 1",
                "7 REGION = eu-west — private and internal",
            ]
        })
        #expect(detail.notes.items.map(\.canReveal) == [true, false, false, false])

        harness.runner.replaceStub(argumentsPrefix: ["secret", "list", "--org=Example-Org"], with: .success(OrganizationDriftReviewTests.secrets))
        harness.runner.replaceStub(argumentsPrefix: ["variable", "list", "--org=Example-Org"], with: .success("[]"))
        detail.refreshNow()
        #expect(await TestFixtures.eventually { detail.refresh != nil && !detail.isRefreshing })
        let npm = try #require(detail.notes.items.first { $0.name == "NPM_TOKEN" })
        #expect(npm.mark == .changedAtSource)
    }

    @Test func aChangeAtTheSourceWinsOverOneWaitingForSync() {
        #expect(NotesMarkModel.mark(isChangedAtSource: true, status: .modified) == .changedAtSource)
        #expect(NotesMarkModel.mark(isChangedAtSource: true, status: .synced) == .changedAtSource)
        let pending = ConfigSyncStatus.allCases.filter { NotesMarkModel.mark(isChangedAtSource: false, status: $0) == .pending }
        #expect(pending == [.added, .modified, .deleted, .blocked, .willPush])
    }

    @Test func theDriftReportMarksTheItemsOfOneScope() {
        let token = ConfigItemID()
        let region = ConfigItemID()
        let report = DriftFixtures.report([
            DriftFixtures.item(.secretModified, .secret, "API_TOKEN", itemID: token),
            DriftFixtures.item(.variableModified, .variable, "REGION", environment: "production", itemID: region),
            DriftFixtures.item(.remoteAdded, .secret, "ONLY_ON_GITHUB", itemID: nil),
            DriftFixtures.environment(.environmentAdded, "staging"),
        ])
        #expect(report.changedItemIDs(in: .repository) == [token])
        #expect(report.changedItemIDs(in: .environment(DriftFixtures.environmentID)) == [region])
    }
}
