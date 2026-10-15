import AppKit
import EnvTools
import Foundation
import SwiftUI
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// v0.1.1 bulk paste in `EnvImportScreen`: prefill from ⌘V, live parse with debounce, kind
/// defaults per tab, bulk marking, the credential warning badge, Overwrite All, the target scope
/// default and the paste buffer's lifetime.
@MainActor
@Suite("Env import: bulk paste")
struct EnvFilePasteViewModelTests {
    typealias Fixture = EnvFileImportViewModelTests.Fixture

    static let pastedEnv = "API_TOKEN=\(EnvFileFixtures.secretValue)\nBASE_URL=\(EnvFileFixtures.variableValue)\n"

    static func row(_ model: EnvImportViewModel, _ name: String) throws -> EnvImportRowModel {
        try EnvFileImportViewModelTests.row(model, name)
    }

    static func kinds(_ model: EnvImportViewModel) -> [String: ConfigKind] {
        Dictionary(uniqueKeysWithValues: model.rows.map { ($0.name, $0.kind) })
    }

    // MARK: - Prefill

    @Test func pastedBufferPrefillsTheEditorAndParsesAtOnce() async throws {
        let fixture = try await Fixture()
        let buffer = EnvPasteBuffer(SecretBytes(utf8: Self.pastedEnv))
        #expect(!String(describing: buffer).contains(EnvFileFixtures.secretValue))

        let model = fixture.viewModel(defaultKind: .secret, start: .pasted(buffer))

        #expect(!buffer.hasContents)
        #expect(model.step == .paste)
        #expect(model.sourceKind == .paste)
        #expect(model.focusesPasteEditor)
        #expect(model.pastedText == Self.pastedEnv)
        #expect(!model.isParsePending)
        #expect(model.rows.map(\.name) == ["API_TOKEN", "BASE_URL"])
        #expect(model.defaultAction == .importRows)
        #expect(model.canImport)
        #expect(!EnvFileImportViewModelTests.visibleText(model).contains(EnvFileFixtures.secretValue))
    }

    @Test func singleLinePasteStillUsesThePreview() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel(
            defaultKind: .secret,
            start: .pasted(EnvPasteBuffer(SecretBytes(utf8: "API_TOKEN=\(EnvFileFixtures.secretValue)")))
        )
        #expect(model.step == .paste)
        #expect(model.rows.map(\.name) == ["API_TOKEN"])
        #expect(model.canImport)

        model.importRows()
        guard case .done(let result) = model.step else {
            Issue.record("Expected the done step")
            return
        }
        #expect(result.added == ["API_TOKEN"])
        #expect(model.pastedText.isEmpty)
    }

    @Test func pasteMultipleOpensAnEmptyFocusedEditorWithAnEmptyState() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel(defaultKind: .variable, start: .pasteEditor)
        #expect(model.step == .paste)
        #expect(model.focusesPasteEditor)
        #expect(model.isPastedTextEmpty)
        #expect(model.rows.isEmpty)
        #expect(model.issues.isEmpty)
        #expect(!model.canImport)

        // The toolbar's Import .env opens the file chooser.
        let toolbar = fixture.viewModel()
        #expect(toolbar.step == .source)
        #expect(!toolbar.focusesPasteEditor)
    }

    @Test func pasteButtonFillsTheEditorAndParsesAtOnce() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel(start: .pasteEditor)
        model.pasteFromClipboard(["FIRST=1"])
        #expect(model.rows.map(\.name) == ["FIRST"])
        #expect(!model.isParsePending)

        model.pasteFromClipboard(["SECOND=2"])
        #expect(model.pastedText == "FIRST=1\nSECOND=2")
        #expect(model.rows.map(\.name) == ["FIRST", "SECOND"])
    }

    // MARK: - Live parse

    @Test func editsAreParsedAfterTheDebounce() async throws {
        let fixture = try await Fixture()
        let clock = fixture.harness.clock
        let model = fixture.viewModel(start: .pasteEditor)

        model.pastedText = "FIRST=1"
        #expect(model.isParsePending)
        #expect(!model.canImport)
        #expect(model.rows.isEmpty)
        await clock.waitForSleepers(count: 1)

        // Typing again restarts the pause.
        clock.advance(by: Theme.Durations.envPasteParseDebounce / 2)
        model.pastedText = "FIRST=1\nSECOND=2"
        await clock.waitForSleepers(count: 1)
        clock.advance(by: Theme.Durations.envPasteParseDebounce / 2)
        await Task.yield()
        #expect(model.isParsePending)
        #expect(model.rows.isEmpty)

        let task = try #require(model.parseTask)
        clock.advance(by: Theme.Durations.envPasteParseDebounce)
        await task.value

        #expect(!model.isParsePending)
        #expect(model.rows.map(\.name) == ["FIRST", "SECOND"])
        #expect(model.canImport)
    }

    @Test func liveParseListsIssuesWithLineNumbersAndShowsNothingForUnparsableText() async throws {
        let fixture = try await Fixture()
        let model = fixture.reviewing("not a pair")
        #expect(model.rows.isEmpty)
        #expect(model.issues.map(\.line) == [1])
        #expect(!model.canImport)

        model.pastedText = "GOOD=1\nnot a pair\nQUOTED=\"FXV_UNCLOSED_VALUE"
        model.parsePastedText()
        #expect(model.rows.map(\.name) == ["GOOD"])
        #expect(model.issues.map(\.line) == [2, 3])
        #expect(model.issues.first?.localizedLocation.hasPrefix("Line 2") == true)

        model.clearPastedText()
        #expect(model.rows.isEmpty)
        #expect(model.issues.isEmpty)
        #expect(model.isPastedTextEmpty)
    }

    @Test func rowChangesSurviveAReparse() async throws {
        let fixture = try await Fixture()
        let model = fixture.reviewing("API_TOKEN=one\nBASE_URL=two")
        model.setKind(.variable, forRow: try Self.row(model, "API_TOKEN").id)
        model.setIncluded(false, forRow: try Self.row(model, "BASE_URL").id)
        model.setName("RENAMED_URL", forRow: try Self.row(model, "BASE_URL").id)
        let values = try #require(model.preview?.candidates.map(\.value))

        model.pastedText = "NEW_FIRST=0\nAPI_TOKEN=one\nBASE_URL=two"
        model.parsePastedText()

        let allIsWiped = values.allSatisfy { $0.isWiped }
        #expect(allIsWiped)
        #expect(try Self.row(model, "API_TOKEN").kind == .variable)
        let renamed = try Self.row(model, "RENAMED_URL")
        #expect(!renamed.isIncluded)
        #expect(try Self.row(model, "NEW_FIRST").isIncluded)
    }

    // MARK: - Kind defaults

    @Test func variablesTabDefaultsEveryRowToVariableAndWarnsForCredentials() async throws {
        let fixture = try await Fixture()
        let model = fixture.reviewing(Self.pastedEnv, defaultKind: .variable)
        #expect(Self.kinds(model) == ["API_TOKEN": .variable, "BASE_URL": .variable])

        let token = try Self.row(model, "API_TOKEN")
        #expect(token.looksLikeCredential)
        #expect(model.kindWarning(for: token) != nil)
        #expect(model.kindWarning(for: try Self.row(model, "BASE_URL")) == nil)

        model.makeSecret(forRow: token.id)
        let fixed = try Self.row(model, "API_TOKEN")
        #expect(fixed.kind == .secret)
        #expect(model.kindWarning(for: fixed) == nil)
    }

    @Test func secretsTabDefaultsEveryRowToSecret() async throws {
        let fixture = try await Fixture()
        let model = fixture.reviewing(Self.pastedEnv, defaultKind: .secret)
        #expect(Self.kinds(model) == ["API_TOKEN": .secret, "BASE_URL": .secret])
        let noWarnings = model.rows.allSatisfy { model.kindWarning(for: $0) == nil }
        #expect(noWarnings)
    }

    @Test func toolbarImportKeepsCredentialAutoDetection() async throws {
        let fixture = try await Fixture()
        let model = fixture.reviewing(Self.pastedEnv)
        #expect(model.defaultKind == nil)
        #expect(Self.kinds(model) == ["API_TOKEN": .secret, "BASE_URL": .variable])
    }

    @Test func markAllSetsEveryRowAndTheRowsLaterEditsAdd() async throws {
        let fixture = try await Fixture()
        let model = fixture.reviewing(Self.pastedEnv, defaultKind: .secret)
        model.setKind(.secret, forRow: try Self.row(model, "BASE_URL").id)

        model.markAll(as: .variable)
        #expect(model.bulkKind == .variable)
        #expect(Self.kinds(model) == ["API_TOKEN": .variable, "BASE_URL": .variable])
        #expect(model.kindWarning(for: try Self.row(model, "API_TOKEN")) != nil)

        model.pastedText = Self.pastedEnv + "REGION=eu\n"
        model.parsePastedText()
        #expect(Self.kinds(model) == ["API_TOKEN": .variable, "BASE_URL": .variable, "REGION": .variable])

        model.markAll(as: .secret)
        #expect(Self.kinds(model) == ["API_TOKEN": .secret, "BASE_URL": .secret, "REGION": .secret])
    }

    // MARK: - Conflicts and target scope

    @Test func overwriteAllReplacesEveryConflict() async throws {
        let fixture = try await Fixture(items: [
            TestFixtures.item(.variable, "BASE_URL", "old-url"),
            TestFixtures.item(.variable, "REGION", "old-region"),
        ])
        let model = fixture.reviewing("BASE_URL=new-url\nREGION=new-region\nNEW_VAR=1", defaultKind: .variable)
        #expect(model.canOverwriteAll)
        #expect(try Self.row(model, "BASE_URL").onConflict == .skip)

        model.overwriteAllConflicts()

        #expect(!model.canOverwriteAll)
        #expect(try Self.row(model, "BASE_URL").onConflict == .overwrite)
        #expect(try Self.row(model, "REGION").onConflict == .overwrite)
        model.importRows()
        guard case .done(let result) = model.step else {
            Issue.record("Expected the done step")
            return
        }
        #expect(Set(result.overwritten) == ["BASE_URL", "REGION"])
        #expect(result.added == ["NEW_VAR"])
        let stored = try await EnvFileFixtures.value(fixture.harness, repositoryID: fixture.repositoryID, kind: .variable, name: "REGION")
        #expect(stored == "new-region")
    }

    @Test func targetScopeDefaultsToTheOpenEnvironmentAndStaysChangeable() async throws {
        let fixture = try await Fixture(environments: [RepoCreationEnvironmentDraftModel(name: "staging")])
        let staging = try #require(
            try fixture.harness.data.config.scopes(repositoryID: fixture.repositoryID).first { $0.scope != .repository }?.scope
        )
        let model = fixture.viewModel(
            scope: staging,
            defaultKind: .variable,
            start: .pasted(EnvPasteBuffer(SecretBytes(utf8: "REGION=eu")))
        )
        #expect(model.targetScope == staging)
        #expect(model.targetProblem == nil)

        model.selectTarget(.repository)
        #expect(model.targetScope == .repository)
    }

    @Test func changingTheTargetResetsOverwriteChoices() async throws {
        let fixture = try await Fixture(
            items: [TestFixtures.item(.variable, "BASE_URL", "old-url")],
            environments: [RepoCreationEnvironmentDraftModel(name: "staging")]
        )
        let staging = try #require(
            try fixture.harness.data.config.scopes(repositoryID: fixture.repositoryID).first { $0.scope != .repository }?.scope
        )
        let model = fixture.reviewing("BASE_URL=new-url\nNEW_VAR=1", defaultKind: .variable)
        model.overwriteAllConflicts()
        #expect(try Self.row(model, "BASE_URL").onConflict == .overwrite)

        model.selectTarget(staging)
        let nothingOverwrites = model.rows.allSatisfy { $0.onConflict == .skip }
        #expect(nothingOverwrites)

        // Back on the scope with the conflict: reviewed again, and the choice does not come back
        // with a re-parse either.
        model.selectTarget(.repository)
        #expect(model.canOverwriteAll)
        #expect(try Self.row(model, "BASE_URL").onConflict == .skip)
        model.pastedText += "\nMORE=1"
        model.parsePastedText()
        #expect(try Self.row(model, "BASE_URL").onConflict == .skip)
    }

    // MARK: - Unsafe pastes

    /// Synthetic key material with `=` padding (not a real key).
    static let unquotedPEMEnv = """
    REGION=eu
    JWT_KEY=-----BEGIN FXV FIXTURE KEY-----
    FXVFIXTUREpemBODYfirstLINEabc
    FXVfixture+pem/BODYline==
    -----END FXV FIXTURE KEY-----
    LOG_LEVEL=debug
    """

    @Test func unquotedMultilineKeyNeverBecomesARow() async throws {
        let fixture = try await Fixture()
        let model = fixture.reviewing(Self.unquotedPEMEnv, defaultKind: .variable)
        #expect(model.rows.map(\.name) == ["REGION", "LOG_LEVEL"])
        #expect(model.issues.map(\.line) == [2])
        #expect(model.issues.first?.localizedLocation == "Line 2 · JWT_KEY")
        #expect(model.errorIssueCount == 1)
        let text = EnvFileImportViewModelTests.visibleText(model)
        #expect(!text.contains("FXVFIXTUREpemBODY"))
        #expect(!text.uppercased().contains("FXVFIXTURE_PEM"))
    }

    @Test func rowWhoseKeyNeededACharacterFixIsNotPreSelected() async throws {
        let fixture = try await Fixture()
        let model = fixture.reviewing("FXVfixture+chunk/ab==\napi-url=x\nREGION=eu", defaultKind: .variable)
        #expect(try !Self.row(model, "FXVFIXTURE_CHUNK_AB").isIncluded)
        #expect(try !Self.row(model, "API_URL").isIncluded)
        #expect(try Self.row(model, "REGION").isIncluded)
        #expect(model.includedRows.map(\.name) == ["REGION"])
    }

    @Test func lineWithoutEqualsIsNotEchoedInTheIssues() async throws {
        let fixture = try await Fixture()
        let model = fixture.reviewing("ghp_FXV_FIXTURE_TOKEN\nREGION=eu")
        #expect(model.issues.map(\.line) == [1])
        let locations = model.issues.map(\.localizedLocation)
        #expect(locations == ["Line 1"])
        #expect(!EnvFileImportViewModelTests.visibleText(model).contains("ghp_FXV_FIXTURE_TOKEN"))
    }

    // MARK: - Large pastes

    @Test func duplicateNamesAreFlaggedAndFollowEdits() async throws {
        let fixture = try await Fixture()
        let model = fixture.reviewing("REGION=eu\nregion=us\nOTHER=1", defaultKind: .variable)
        let first = try #require(model.rows.first { $0.originalKey == "REGION" })
        let second = try #require(model.rows.first { $0.originalKey == "region" })
        // The parser folds `region` into REGION_2, so rename it back to collide.
        model.setName("REGION", forRow: second.id)
        #expect(model.nameProblem(for: try #require(model.rows.first { $0.id == second.id })) != nil)
        #expect(model.nameProblem(for: first) == nil)
        #expect(!model.canImport)

        model.setIncluded(false, forRow: second.id)
        #expect(model.canImport)
        model.setIncluded(true, forRow: second.id)
        #expect(!model.canImport)
        model.setKind(.secret, forRow: second.id)
        #expect(model.canImport)
    }

    @Test func aStaleBackgroundParseIsDiscarded() async throws {
        let fixture = try await Fixture()
        let clock = fixture.harness.clock
        let model = fixture.viewModel(start: .pasteEditor)

        model.pastedText = "STALE=1"
        await clock.waitForSleepers(count: 1)
        let stale = try #require(model.parseTask)
        // An explicit parse (a Paste button, Clear) runs before the debounced one finishes.
        model.pastedText = "FRESH=1"
        model.parsePastedText()
        clock.advance(by: Theme.Durations.envPasteParseDebounce)
        await stale.value

        #expect(!model.isParsePending)
        #expect(model.rows.map(\.name) == ["FRESH"])
    }

    // MARK: - Buffer lifetime

    @Test func closingTheSheetClearsThePasteBufferAndPendingParse() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel(start: .pasted(EnvPasteBuffer(SecretBytes(utf8: Self.pastedEnv))))
        let values = try #require(model.preview?.candidates.map(\.value))
        model.pastedText += "MORE=1\n"
        #expect(model.parseTask != nil)

        model.discard()

        #expect(model.pastedText.isEmpty)
        #expect(model.parseTask == nil)
        #expect(!model.isParsePending)
        #expect(model.rows.isEmpty)
        #expect(model.preview == nil)
        let allIsWiped = values.allSatisfy { $0.isWiped }
        #expect(allIsWiped)
    }

    @Test func switchingToFileClearsThePastedText() async throws {
        let fixture = try await Fixture()
        let model = fixture.reviewing(Self.pastedEnv)
        let values = try #require(model.preview?.candidates.map(\.value))

        model.sourceKind = .file

        #expect(model.step == .source)
        #expect(model.pastedText.isEmpty)
        #expect(model.rows.isEmpty)
        let allIsWiped = values.allSatisfy { $0.isWiped }
        #expect(allIsWiped)

        model.sourceKind = .paste
        #expect(model.step == .paste)
        #expect(model.isPastedTextEmpty)
    }

    @Test func pasteEditorKeepsTextAsTypedAndWritesNothingBackOnceDismantled() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel(start: .pasteEditor)
        let coordinator = EnvPasteEditorCoordinator(text: Bindable(model).pastedText)
        let container = EnvPasteEditorContainerView(scrollView: SecretTextView.makeScrollableEditor(), focusesOnWindow: false)
        let textView = try #require(container.textView)
        textView.delegate = coordinator

        textView.string = Self.pastedEnv
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(model.pastedText == Self.pastedEnv)

        // Focus leaving the editor (a click in the table) does not rewrite the text: the D32
        // trailing line break rule is for single values only.
        textView.delegate?.textDidEndEditing?(Notification(name: NSText.didEndEditingNotification, object: textView))
        #expect(model.pastedText == Self.pastedEnv)
        #expect(textView.string == Self.pastedEnv)

        // The sheet closes: discard, then SwiftUI dismantles the editor.
        model.discard()
        EnvPasteEditorView.dismantleNSView(container, coordinator: coordinator)
        #expect(textView.string.isEmpty)
        #expect(textView.delegate == nil)
        textView.string = Self.pastedEnv
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(model.pastedText.isEmpty)
    }

    @Test func lockClearsThePastedText() async throws {
        let fixture = try await Fixture()
        let model = fixture.reviewing(Self.pastedEnv)
        fixture.harness.app.lock(trigger: .manual)
        #expect(model.pastedText.isEmpty)
        #expect(model.preview == nil)
    }
}
