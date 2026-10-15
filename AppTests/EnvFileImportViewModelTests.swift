import EnvTools
import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// `EnvImportScreen` (§10, M5): source, parsed table (key fixes, credential pre-marking,
/// conflicts, target scope), import through `EnvFileRepository`, and value hygiene.
@MainActor
@Suite("Env import")
struct EnvFileImportViewModelTests {
    @MainActor
    struct Fixture {
        let harness: TestHarness
        let recorder = ActionRecorder()
        let repositoryID: RepoID

        init(items: [RepoCreationItemDraftModel] = [], environments: [RepoCreationEnvironmentDraftModel] = []) async throws {
            harness = try await TestHarness(vault: .unlocked)
            repositoryID = try await harness.stageRepository(items: items, environments: environments)
        }

        func viewModel(scope: ConfigScope = .repository, fileURL: URL? = nil) -> EnvImportViewModel {
            EnvImportViewModel(
                context: EnvImportContext(repositoryID: repositoryID, scope: scope, fileURL: fileURL),
                dependencies: harness.dependencies(recorder: recorder)
            )
        }

        /// A view model in the review step over pasted `text`.
        func reviewing(_ text: String, scope: ConfigScope = .repository) -> EnvImportViewModel {
            let model = viewModel(scope: scope)
            model.sourceKind = .paste
            model.pastedText = text
            model.reviewPastedText()
            return model
        }
    }

    static func row(_ model: EnvImportViewModel, _ name: String) throws -> EnvImportRowModel {
        try #require(model.rows.first { $0.name == name })
    }

    /// Every user-visible text of the review step.
    static func visibleText(_ model: EnvImportViewModel) -> String {
        var texts = model.rows.flatMap { row in
            [row.name, row.originalKey] + model.keyNotes(for: row)
                + [model.nameProblem(for: row), model.credentialHint(for: row), model.kindWarning(for: row)].compactMap { $0 }
        }
        texts += model.issues.map { "\($0.localizedLocation) \($0.localizedMessage)" }
        texts.append(String(describing: model.rows))
        return texts.joined(separator: "\n")
    }

    // MARK: - Source

    @Test func sampleFilePreMarksSecretsAndSuggestsKeyFixes() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel()
        #expect(model.step == .source)
        #expect(model.defaultAction == .chooseFile)

        await model.loadFile(at: EnvFileFixtures.sampleEnvURL)

        #expect(model.alert == nil)
        #expect(model.step == .review)
        #expect(model.defaultAction == .importRows)
        #expect(model.sourceFileName == "sample.env")
        let kinds = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.name, $0.kind) })
        #expect(kinds == [
            "APP_NAME": .variable,
            "API_BASE_URL": .variable,
            "DATABASE_URL": .secret,
            "STRIPE_API_KEY": .secret,
            "WELCOME_MESSAGE": .variable,
            "SESSION_TIMEOUT": .variable,
            "SIGNING_CERT_PEM": .secret,
            "FEATURE_FLAGS": .variable,
            "GH_TOKEN_NAME": .secret,
        ])
        let allIsIncluded = model.rows.allSatisfy { $0.isIncluded }
        #expect(allIsIncluded)

        let fixed = try Self.row(model, "API_BASE_URL")
        #expect(fixed.originalKey == "api-base-url")
        #expect(model.keyNotes(for: fixed).first?.contains("Fixed from api-base-url") == true)
        let reserved = try Self.row(model, "GH_TOKEN_NAME")
        #expect(reserved.keyStatus == .needsFix(.reservedPrefix))
        let database = try Self.row(model, "DATABASE_URL")
        #expect(database.credentialReasons == [.urlWithCredentials])
        #expect(model.credentialHint(for: database) != nil)
        #expect(model.credentialHint(for: try Self.row(model, "APP_NAME")) == nil)

        #expect(model.issues.map(\.line) == [10, 12])
        #expect(model.issues.first?.localizedLocation == "Line 10 · FEATURE_FLAGS")
        #expect(model.errorIssueCount == 0)
        #expect(model.canImport)

        let text = Self.visibleText(model)
        for fragment in EnvFileFixtures.sampleValueFragments {
            #expect(!text.contains(fragment))
        }
    }

    @Test func contextFileIsLoadedWhenTheSheetOpens() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel(fileURL: EnvFileFixtures.sampleEnvURL)
        #expect(await TestFixtures.eventually { model.step == .review })
        #expect(model.rows.count == 9)
    }

    @Test func unreadableFileShowsAnErrorAndStaysOnSource() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel()
        await model.loadFile(at: fixture.harness.sandbox.appending(path: "missing.env"))
        #expect(model.step == .source)
        #expect(model.alert?.title == "The .env file could not be read")
    }

    @Test func pastedTextIsParsedThenClearedAndImported() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel()
        model.sourceKind = .paste
        #expect(model.defaultAction == .reviewPastedText)
        #expect(!model.canReviewPastedText)
        model.pastedText = "  \n "
        #expect(!model.canReviewPastedText)

        model.pastedText = "API_TOKEN=\(EnvFileFixtures.secretValue)\nBASE_URL=\(EnvFileFixtures.variableValue)\n"
        model.reviewPastedText()

        #expect(model.pastedText.isEmpty)
        #expect(model.step == .review)
        #expect(model.sourceFileName == nil)
        #expect(model.rows.map(\.name) == ["API_TOKEN", "BASE_URL"])
        #expect(model.rows.map(\.kind) == [.secret, .variable])
        let values = try #require(model.preview?.candidates.map(\.value))

        model.importRows()

        guard case .done(let result) = model.step else {
            Issue.record("Expected the done step")
            return
        }
        #expect(model.defaultAction == .done)
        #expect(result.added == ["API_TOKEN", "BASE_URL"])
        #expect(model.hasPendingChanges(result))
        let allIsWiped = values.allSatisfy { $0.isWiped }
        #expect(allIsWiped)
        #expect(model.preview == nil)
        let summary = model.summaryLines(for: result).joined(separator: "\n")
        #expect(summary.contains("API_TOKEN"))
        #expect(!summary.contains(EnvFileFixtures.secretValue))
        #expect(!summary.contains(EnvFileFixtures.variableValue))
        #expect(!String(describing: result).contains(EnvFileFixtures.secretValue))

        let stored = try await EnvFileFixtures.value(fixture.harness, repositoryID: fixture.repositoryID, kind: .secret, name: "API_TOKEN")
        #expect(stored == EnvFileFixtures.secretValue)
    }

    // MARK: - Conflicts, kinds, names

    @Test func existingNamesDefaultToSkipAndCanBeOverwritten() async throws {
        let fixture = try await Fixture(items: [TestFixtures.item(.secret, "API_TOKEN", "old-value")])
        let model = fixture.reviewing("API_TOKEN=new-value\nNEW_VAR=1")
        let existing = try Self.row(model, "API_TOKEN")
        #expect(model.hasConflict(existing))
        #expect(existing.onConflict == .skip)
        #expect(!model.hasConflict(try Self.row(model, "NEW_VAR")))

        model.importRows()
        guard case .done(let skipped) = model.step else {
            Issue.record("Expected the done step")
            return
        }
        #expect(skipped.added == ["NEW_VAR"])
        #expect(skipped.skipped.map(\.reason) == [.existingItem])
        #expect(try await EnvFileFixtures.value(fixture.harness, repositoryID: fixture.repositoryID, kind: .secret, name: "API_TOKEN") == "old-value")

        let overwrite = fixture.reviewing("API_TOKEN=new-value")
        overwrite.setConflictChoice(.overwrite, forRow: try Self.row(overwrite, "API_TOKEN").id)
        overwrite.importRows()
        guard case .done(let replaced) = overwrite.step else {
            Issue.record("Expected the done step")
            return
        }
        #expect(replaced.overwritten == ["API_TOKEN"])
        #expect(try await EnvFileFixtures.value(fixture.harness, repositoryID: fixture.repositoryID, kind: .secret, name: "API_TOKEN") == "new-value")
    }

    @Test func changingTheKindRecomputesConflictsAndWarnsForCredentials() async throws {
        let fixture = try await Fixture(items: [TestFixtures.item(.secret, "API_TOKEN", "old-value")])
        let model = fixture.reviewing("API_TOKEN=new-value")
        let id = try Self.row(model, "API_TOKEN").id
        #expect(model.kindWarning(for: try Self.row(model, "API_TOKEN")) == nil)

        model.setKind(.variable, forRow: id)

        let row = try Self.row(model, "API_TOKEN")
        #expect(!model.hasConflict(row))
        #expect(model.kindWarning(for: row) != nil)
    }

    @Test func invalidAndDuplicateNamesBlockTheImport() async throws {
        let fixture = try await Fixture()
        let model = fixture.reviewing("api-key=one\nOTHER_KEY=two")
        let first = try Self.row(model, "API_KEY")
        #expect(first.differsFromSuggestion == false)

        model.setName("1BAD", forRow: first.id)
        #expect(model.nameProblem(for: try #require(model.rows.first { $0.id == first.id })) != nil)
        #expect(!model.canImport)

        model.useSuggestedName(forRow: first.id)
        #expect(try Self.row(model, "API_KEY").id == first.id)
        #expect(model.canImport)

        let second = try Self.row(model, "OTHER_KEY")
        model.setName("api_key", forRow: second.id)
        let duplicate = try #require(model.rows.first { $0.id == second.id })
        #expect(model.nameProblem(for: duplicate) != nil)
        #expect(!model.canImport)

        model.setIncluded(false, forRow: second.id)
        #expect(model.canImport)
        #expect(model.includedRows.count == 1)
    }

    @Test func rowsWithUnusableValuesCannotBeIncluded() async throws {
        let fixture = try await Fixture()
        let model = fixture.reviewing("EMPTY=\nOK=1")
        let empty = try Self.row(model, "EMPTY")
        #expect(!empty.canInclude)
        #expect(!empty.isIncluded)
        #expect(model.keyNotes(for: empty).contains { $0.hasPrefix("Not importable") })

        model.setIncluded(true, forRow: empty.id)
        #expect(try Self.row(model, "EMPTY").isIncluded == false)
        model.setAllIncluded(false)
        #expect(model.includedRows.isEmpty)
        #expect(!model.canImport)
        model.setAllIncluded(true)
        #expect(model.includedRows.map(\.name) == ["OK"])
    }

    @Test func parseErrorsAreListedWithLineNumbers() async throws {
        let fixture = try await Fixture()
        let model = fixture.reviewing("GOOD=1\nnot a pair\nQUOTED=\"FXV_UNCLOSED_VALUE")
        #expect(model.rows.map(\.name) == ["GOOD"])
        #expect(model.issues.map(\.line) == [2, 3])
        #expect(model.errorIssueCount == 2)
        let allErrors = model.issues.allSatisfy { $0.severity == .error }
        #expect(allErrors)
        #expect(!Self.visibleText(model).contains("FXV_UNCLOSED_VALUE"))
    }

    // MARK: - Target scope

    @Test func targetScopeListsEnvironmentsAndImportsThere() async throws {
        let fixture = try await Fixture(
            items: [TestFixtures.item(.variable, "REGION", "repo-level")],
            environments: [RepoCreationEnvironmentDraftModel(name: "staging")]
        )
        let model = fixture.reviewing("REGION=eu")
        #expect(model.scopeOptions.map(\.title) == ["Repository", "staging"])
        let allIsEditable = model.scopeOptions.allSatisfy { $0.isEditable }
        #expect(allIsEditable)
        #expect(model.hasConflict(try Self.row(model, "REGION")))

        let staging = try #require(model.scopeOptions.last?.scope)
        model.selectTarget(staging)
        #expect(model.targetScope == staging)
        #expect(!model.hasConflict(try Self.row(model, "REGION")))

        model.importRows()
        guard case .done(let result) = model.step else {
            Issue.record("Expected the done step")
            return
        }
        #expect(result.added == ["REGION"])
        #expect(model.summaryLines(for: result).first?.contains("staging") == true)
        let stored = try await EnvFileFixtures.value(
            fixture.harness,
            repositoryID: fixture.repositoryID,
            scope: staging,
            kind: .variable,
            name: "REGION"
        )
        #expect(stored == "eu")
        #expect(try await EnvFileFixtures.value(fixture.harness, repositoryID: fixture.repositoryID, kind: .variable, name: "REGION") == "repo-level")
    }

    // MARK: - Value hygiene

    @Test func startOverWipesTheParsedValues() async throws {
        let fixture = try await Fixture()
        let model = fixture.reviewing("API_TOKEN=\(EnvFileFixtures.secretValue)")
        let values = try #require(model.preview?.candidates.map(\.value))

        model.startOver()

        #expect(model.step == .source)
        #expect(model.rows.isEmpty)
        #expect(model.preview == nil)
        let allIsWiped = values.allSatisfy { $0.isWiped }
        #expect(allIsWiped)
    }

    @Test func closingTheSheetWipesValuesAndPastedText() async throws {
        let fixture = try await Fixture()
        let model = fixture.reviewing("API_TOKEN=\(EnvFileFixtures.secretValue)")
        let values = try #require(model.preview?.candidates.map(\.value))
        model.pastedText = "LEFTOVER=\(EnvFileFixtures.secretValue)"

        model.discard()

        let allIsWiped = values.allSatisfy { $0.isWiped }
        #expect(allIsWiped)
        #expect(model.pastedText.isEmpty)
        #expect(model.rows.isEmpty)
    }

    @Test func lockWipesValuesThroughTheLockObserver() async throws {
        let fixture = try await Fixture()
        let model = fixture.reviewing("API_TOKEN=\(EnvFileFixtures.secretValue)")
        let values = try #require(model.preview?.candidates.map(\.value))

        fixture.harness.app.lock(trigger: .manual)

        let allIsWiped = values.allSatisfy { $0.isWiped }
        #expect(allIsWiped)
        #expect(model.preview == nil)
        #expect(model.rows.isEmpty)
    }

    @Test func importWhileLockedFailsWithoutWriting() async throws {
        let fixture = try await Fixture()
        let model = fixture.reviewing("NEW_VAR=1")
        fixture.harness.vaultManager.lock()

        model.importRows()

        #expect(model.step == .review)
        #expect(model.alert != nil)
    }
}
