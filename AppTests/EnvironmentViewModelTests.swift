import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// The environment sheets (§7.1, §7.6, §10, D20, M3–M5) over an in-memory vault: New, Settings
/// with the branch policy editor, Rename (local, case-only, guided recreate) and Duplicate.
@MainActor
@Suite("Environment sheets")
struct EnvironmentViewModelTests {
    private func context(_ id: RepoID, _ environment: EnvironmentModel) -> EnvironmentContext {
        EnvironmentContext(repositoryID: id, environmentID: environment.id)
    }

    // MARK: - New environment

    @Test func newEnvironmentChecksNamesByFoldKey() async throws {
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let model = NewEnvironmentViewModel(
            context: NewEnvironmentContext(repositoryID: id),
            dependencies: harness.dependencies(recorder: ActionRecorder())
        )
        #expect(model.canEdit)
        #expect(model.nameStatus == .empty)
        #expect(!model.canCreate)

        model.name = "STAGING"
        #expect(model.nameStatus == .taken)
        #expect(model.nameStatus.note?.isError == true)
        model.name = " qa"
        #expect(model.nameStatus == .invalid(NameRule.leadingOrTrailingWhitespace.localizedMessage))
        model.name = "a/b"
        if case .invalid = model.nameStatus {} else {
            Issue.record("a slash is rejected (D29)")
        }
        model.name = "Producción"
        #expect(model.nameStatus == .available)
        #expect(model.canCreate)

        model.policy.choice = .selected
        model.policy.newPattern = "release/*"
        #expect(!model.canCreate, "the typed rule is added first")
        model.policy.addPattern()
        #expect(model.canCreate)
        #expect(model.create())

        let created = try EditorFixtures.environment(harness, id, named: "Producción")
        #expect(created.id == model.createdID)
        #expect(created.branchPolicy.kind == .custom)
        #expect(created.branchPolicy.activePatterns.map(\.pattern) == ["release/*"])

        // The same name in another case is now taken.
        model.load()
        model.name = "PRODUCCIÓN"
        #expect(model.nameStatus == .taken)
    }

    @Test func newEnvironmentRestoresADeletedOne() async throws {
        let (harness, id) = try await EditorFixtures.importedHarness()
        let staging = try EditorFixtures.environment(harness, id, named: "staging")
        try harness.data.config.deleteEnvironment(staging.id)

        let model = NewEnvironmentViewModel(
            context: NewEnvironmentContext(repositoryID: id),
            dependencies: harness.dependencies(recorder: ActionRecorder())
        )
        #expect(model.showsPlanNote, "private repository")
        model.name = "Staging"
        #expect(model.nameStatus == .restoresDeleted)
        #expect(model.nameStatus.note?.tone == .info)
        #expect(model.create())
        #expect(model.createdID == staging.id, "the tombstone is revived")
    }

    @Test func newEnvironmentNeedsAdmin() async throws {
        let (harness, id) = try await EditorFixtures.importedHarness(permission: "WRITE")
        let model = NewEnvironmentViewModel(
            context: NewEnvironmentContext(repositoryID: id),
            dependencies: harness.dependencies(recorder: ActionRecorder())
        )
        model.name = "qa"
        #expect(model.readOnlyReason == .adminRequired)
        #expect(!model.canCreate)
        #expect(!model.create())
    }

    // MARK: - Settings

    @Test func settingsEditTheBranchPolicy() async throws {
        let (harness, id) = try await EditorFixtures.importedHarness()
        let production = try EditorFixtures.environment(harness, id, named: "production")
        let recorder = ActionRecorder()
        let model = EnvironmentSettingsViewModel(
            context: context(id, production),
            dependencies: harness.dependencies(recorder: recorder)
        )
        #expect(model.loadError == nil)
        #expect(model.title == "production Settings")
        #expect(model.policy.choice == .selected)
        #expect(model.policy.patterns.map(\.pattern) == ["release/*"])
        #expect(model.syncNote?.tone == .success)
        #expect(model.foreignRulesNote != nil, "the reviewer rule set on GitHub is kept")
        #expect(model.showsPlanNote)
        #expect(!model.canSave, "nothing changed")

        model.policy.choice = .protectedBranches
        #expect(model.hasChanges)
        #expect(model.syncNote?.tone == .info)
        #expect(model.canSave)
        #expect(model.save())
        let saved = try EditorFixtures.environment(harness, id, named: "production")
        #expect(saved.branchPolicy == .protectedBranches)
        #expect(saved.hasPendingPolicyChange)

        model.rename()
        #expect(recorder.presented == [.renameEnvironment(context(id, production))])
    }

    @Test func settingsOfANewEnvironmentSayItIsNotOnGitHub() async throws {
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let staging = try EditorFixtures.environment(harness, id, named: "staging")
        let model = EnvironmentSettingsViewModel(
            context: context(id, staging),
            dependencies: harness.dependencies(recorder: ActionRecorder())
        )
        #expect(model.syncNote?.message.contains("Not on GitHub yet") == true)
        #expect(model.foreignRulesNote == nil)
        model.policy.choice = .selected
        model.policy.newPattern = "main"
        model.policy.addPattern()
        #expect(model.save())
        let saved = try EditorFixtures.environment(harness, id, named: "staging")
        #expect(saved.branchPolicy.activePatterns.map(\.pattern) == ["main"])
    }

    @Test func settingsAreReadOnlyWithoutAdmin() async throws {
        let (harness, id) = try await EditorFixtures.importedHarness(permission: "WRITE")
        let production = try EditorFixtures.environment(harness, id, named: "production")
        let recorder = ActionRecorder()
        let model = EnvironmentSettingsViewModel(
            context: context(id, production),
            dependencies: harness.dependencies(recorder: recorder)
        )
        #expect(model.readOnlyReason == .adminRequired)
        model.policy.choice = .all
        #expect(!model.canSave)
        #expect(!model.save())
        model.rename()
        #expect(recorder.presented.isEmpty)
    }

    @Test func settingsOfADeletedEnvironmentAreUnavailable() async throws {
        let (harness, id) = try await EditorFixtures.importedHarness()
        let staging = try EditorFixtures.environment(harness, id, named: "staging")
        try harness.data.config.deleteEnvironment(staging.id)
        let model = EnvironmentSettingsViewModel(
            context: context(id, staging),
            dependencies: harness.dependencies(recorder: ActionRecorder())
        )
        #expect(model.loadError == ConfigRepositoryError.environmentDeleted.presentation)
        #expect(!model.canSave)
    }

    // MARK: - Rename (§7.6, D20)

    private func renameModel(
        _ harness: TestHarness,
        _ id: RepoID,
        _ environment: EnvironmentModel,
        recorder: ActionRecorder = ActionRecorder()
    ) async -> RenameEnvironmentViewModel {
        let model = RenameEnvironmentViewModel(
            context: context(id, environment),
            dependencies: harness.dependencies(recorder: recorder)
        )
        await model.load()
        return model
    }

    @Test func renamingAnUnsyncedEnvironmentIsLocal() async throws {
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let staging = try EditorFixtures.environment(harness, id, named: "staging")
        let model = await renameModel(harness, id, staging)
        #expect(model.name == "staging")
        #expect(model.nameStatus == .unchanged)
        #expect(!model.canRename)

        model.name = "stage"
        #expect(model.predictedKind == .local)
        #expect(model.kindNote?.message.contains("not on GitHub yet") == true)
        #expect(model.rename())
        #expect(model.result == .local)
        #expect(try EditorFixtures.environment(harness, id, named: "stage").id == staging.id)
    }

    @Test func caseOnlyRenameStaysLocal() async throws {
        let (harness, id) = try await EditorFixtures.importedHarness()
        let production = try EditorFixtures.environment(harness, id, named: "production")
        let model = await renameModel(harness, id, production)
        model.name = "Production"
        #expect(model.nameStatus == .available)
        #expect(model.predictedKind == .caseOnly)
        #expect(model.kindNote?.tone == .info)
        #expect(!model.isBlockedByMissingValues, "no GitHub write, so missing values do not matter")
        #expect(model.canRename)
        #expect(model.rename())
        #expect(model.result == .caseOnly)
    }

    @Test func syncedRenameIsBlockedWhileValuesAreMissing() async throws {
        let (harness, id) = try await EditorFixtures.importedHarness()
        let production = try EditorFixtures.environment(harness, id, named: "production")
        let recorder = ActionRecorder()
        let model = await renameModel(harness, id, production, recorder: recorder)
        #expect(model.valueMissingSecrets.map(\.name) == ["DEPLOY_KEY"])

        model.name = "prod"
        #expect(model.predictedKind == .recreateOnGitHub)
        #expect(model.isBlockedByMissingValues)
        #expect(!model.canRename)
        #expect(!model.rename())
        #expect(model.missingValuesNote?.message.contains("DEPLOY_KEY") == true)
        #expect(model.missingValuesNote?.message.contains(EditorFixtures.regionValue) == false)

        model.enterValues()
        let secret = try #require(model.valueMissingSecrets.first)
        #expect(recorder.presented == [.itemEditor(ItemEditorContext(
            repositoryID: id,
            scope: .environment(production.id),
            mode: .fill(secret.id)
        ))])
    }

    @Test func syncedRenameExplainsTheGuidedRecreate() async throws {
        let (harness, id) = try await EditorFixtures.importedHarness()
        let staging = try EditorFixtures.environment(harness, id, named: "staging")
        let model = await renameModel(harness, id, staging)
        model.name = "production"
        #expect(model.nameStatus == .taken)
        #expect(!model.canRename)

        model.name = "qa"
        #expect(model.predictedKind == .recreateOnGitHub)
        let note = try #require(model.kindNote)
        #expect(note.tone == .warning)
        #expect(note.message.contains("Deployment history"))
        #expect(model.canRename)
        #expect(model.rename())
        #expect(model.result == .recreateOnGitHub)
        #expect(try EditorFixtures.environment(harness, id, named: "qa").hasPendingRename)

        // Its old name stays reserved until the rename is synced.
        let other = await renameModel(harness, id, try EditorFixtures.environment(harness, id, named: "production"))
        other.name = "staging"
        #expect(other.nameStatus == .reserved)
    }

    @Test func renameBackToTheSyncedNameIsLocal() async throws {
        let (harness, id) = try await EditorFixtures.importedHarness()
        let staging = try EditorFixtures.environment(harness, id, named: "staging")
        try harness.data.config.renameEnvironment(staging.id, to: "qa")
        let model = await renameModel(harness, id, try EditorFixtures.environment(harness, id, named: "qa"))
        model.name = "staging"
        #expect(model.nameStatus == .available)
        #expect(model.predictedKind == .local)
        #expect(model.rename())
        #expect(model.result == .local)
    }

    // MARK: - Duplicate

    @Test func duplicateCopiesPolicyAndValuesAndCarriesValueMissing() async throws {
        let (harness, id) = try await EditorFixtures.importedHarness()
        let production = try EditorFixtures.environment(harness, id, named: "production")
        let model = DuplicateEnvironmentViewModel(
            context: context(id, production),
            dependencies: harness.dependencies(recorder: ActionRecorder())
        )
        await model.load()
        #expect(model.secretCount == 1)
        #expect(model.variableCount == 1)
        #expect(model.valueMissingCount == 1)
        #expect(model.valueMissingNote?.tone == .warning)
        let summary = try #require(model.summary)
        #expect(summary.contains("Selected (1 rules)"))
        #expect(!summary.contains(EditorFixtures.regionValue))

        model.name = "PRODUCTION"
        #expect(model.nameStatus == .taken)
        model.name = "production-copy"
        #expect(model.canDuplicate)
        #expect(model.duplicate())

        let copy = try EditorFixtures.environment(harness, id, named: "production-copy")
        #expect(copy.id == model.createdID)
        #expect(!copy.isSynced)
        #expect(copy.branchPolicy.activePatterns.map(\.pattern) == ["release/*"])
        let region = try await EditorFixtures.item(harness, id, named: "REGION", scope: .environment(copy.id))
        #expect(try EditorFixtures.revealed(harness, region.id) == EditorFixtures.regionValue)
        let deployKey = try await EditorFixtures.item(harness, id, named: "DEPLOY_KEY", scope: .environment(copy.id))
        #expect(!deployKey.hasValue)
        #expect(deployKey.syncStatus == .blocked)
    }

    @Test func duplicateIntoADeletedNameIsRefused() async throws {
        let (harness, id) = try await EditorFixtures.importedHarness()
        let staging = try EditorFixtures.environment(harness, id, named: "staging")
        let production = try EditorFixtures.environment(harness, id, named: "production")
        try harness.data.config.deleteEnvironment(staging.id)
        let model = DuplicateEnvironmentViewModel(
            context: context(id, production),
            dependencies: harness.dependencies(recorder: ActionRecorder())
        )
        await model.load()
        model.name = "staging"
        #expect(model.nameStatus == .reserved)
        #expect(!model.canDuplicate)
    }
}
