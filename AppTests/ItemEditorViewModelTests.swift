import EnvTools
import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// `ConfigItemEditorScreen`'s view model (§10 Sheets, §7.1, §7.8, D11, D32, §5.13) over an
/// in-memory vault: add, edit, fill, convert/move, live name rules, the credential warning, and
/// value hygiene.
@MainActor
@Suite("Item editor")
struct ItemEditorViewModelTests {
    private func editor(
        _ harness: TestHarness,
        _ repositoryID: RepoID,
        scope: ConfigScope = .repository,
        mode: ItemEditorContext.Mode,
        recorder: ActionRecorder = ActionRecorder()
    ) async -> ItemEditorViewModel {
        let model = ItemEditorViewModel(
            context: ItemEditorContext(repositoryID: repositoryID, scope: scope, mode: mode),
            dependencies: harness.dependencies(recorder: recorder)
        )
        await model.load()
        return model
    }

    /// Every user-facing string the editor shows, to check that no value leaks into them.
    private func visibleText(_ model: ItemEditorViewModel) -> [String] {
        var text = [model.title, model.subtitle ?? "", model.primaryTitle]
        text += [model.nameNote?.message, model.kindLockNote?.message].compactMap(\.self)
        text += model.moveNotes.map(\.message)
        text += model.valueNotes.map(\.message)
        text += model.credentialWarning?.reasons ?? []
        text += [model.confirmation?.title, model.confirmation?.message, model.alert?.message].compactMap(\.self)
        return text
    }

    // MARK: - Add

    @Test func addUppercasesTheNameAndSavesTheValue() async throws {
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let model = await editor(harness, id, mode: .add(.secret))
        #expect(model.loadState == .ready)
        #expect(model.title == "New Secret")
        #expect(model.isKindEditable)

        model.name = "database_password"
        #expect(model.name == "DATABASE_PASSWORD")
        #expect(model.nameNote == nil)
        #expect(!model.canSave, "a value is required")

        model.value = EditorFixtures.secretValue
        #expect(model.canSave)
        #expect(model.save())
        #expect(model.value.isEmpty, "the value is dropped after the save")

        let saved = try await EditorFixtures.item(harness, id, named: "DATABASE_PASSWORD")
        #expect(saved.kind == .secret)
        #expect(saved.syncStatus == .added)
        #expect(try EditorFixtures.revealed(harness, saved.id) == EditorFixtures.secretValue)
    }

    @Test func uppercasingKeepsNonASCIILettersVisibleToTheValidator() {
        #expect(ItemEditorViewModel.uppercasingASCII("api_key") == "API_KEY")
        #expect(ItemEditorViewModel.uppercasingASCII("straße") == "STRAßE")
        #expect(ItemEditorViewModel.uppercasingASCII("año_1") == "AñO_1")
    }

    @Test func invalidNamesExplainTheRuleAndSuggestAFix() async throws {
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let model = await editor(harness, id, mode: .add(.variable))
        model.value = "v"

        model.name = "1password"
        #expect(model.nameNote?.isError == true)
        #expect(model.nameNote?.message == NameRule.leadingDigit.localizedMessage)
        #expect(model.suggestedName == "_1PASSWORD")
        #expect(!model.canSave)
        model.applySuggestedName()
        #expect(model.name == "_1PASSWORD")
        #expect(model.nameNote == nil)
        #expect(model.canSave)

        model.name = "github_token"
        #expect(model.nameNote?.message == NameRule.reservedPrefix.localizedMessage)
        #expect(model.suggestedName == "GH_TOKEN")

        model.name = "straße"
        #expect(model.nameNote?.message == NameRule.invalidCharacter.localizedMessage)
        #expect(!model.canSave)

        model.name = "my-key"
        #expect(model.suggestedName == "MY_KEY")
    }

    @Test func duplicateNamesAreCheckedByFoldKeyPerKind() async throws {
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let secret = await editor(harness, id, mode: .add(.secret))
        secret.name = "api_token"
        secret.value = "v"
        #expect(secret.isNameTaken)
        #expect(secret.nameNote?.isError == true)
        #expect(!secret.canSave)

        // A variable may share a secret's name (GitHub keeps them apart).
        let variable = await editor(harness, id, mode: .add(.variable))
        variable.name = "API_TOKEN"
        variable.value = "v"
        #expect(!variable.isNameTaken)
        #expect(variable.canSave)
    }

    @Test func trailingNewlinesAreAnnouncedAndStripped() async throws {
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let model = await editor(harness, id, mode: .add(.secret))
        model.name = "SIGNING_KEY"
        model.value = EditorFixtures.pemValue
        #expect(SecretValueEditor.looksLikeKey(model.value), "the SSH/PEM hint shows")
        let notice = try #require(model.valueNotes.first { $0.tone == .info })
        #expect(notice.message.contains("Trailing line breaks"))
        #expect(model.canSave)

        #expect(model.save())
        #expect(model.didStripTrailingNewlines)
        let saved = try await EditorFixtures.item(harness, id, named: "SIGNING_KEY")
        #expect(try EditorFixtures.revealed(harness, saved.id) == String(EditorFixtures.pemValue.dropLast()))
    }

    @Test func emptyAndOversizedValuesAreRefused() async throws {
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let model = await editor(harness, id, mode: .add(.secret))
        model.name = "ONLY_NEWLINES"
        model.value = "\n\r\n"
        #expect(model.valueNotes.contains { $0.isError })
        #expect(!model.canSave)

        model.value = String(repeating: "a", count: Limits.maxValueBytes + 1)
        #expect(model.valueNotes.first?.message == ValidationError.valueTooLarge(limit: Limits.maxValueBytes).localizedMessage)
        #expect(!model.canSave)
    }

    // MARK: - Credential warning (§5.13)

    @Test func credentialLookingVariableSuggestsASecret() async throws {
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let model = await editor(harness, id, mode: .add(.variable))
        model.name = "DATABASE_URL"
        model.value = EditorFixtures.urlWithCredentials
        let warning = try #require(model.credentialWarning)
        #expect(warning.action == .switchToSecret)
        #expect(warning.reasons.contains(CredentialReason.urlWithCredentials.editorExplanation))
        for text in visibleText(model) {
            #expect(!text.contains("FXV_FIXTURE_PW"), "no value in \(text)")
        }

        model.resolveCredentialWarning()
        #expect(model.kind == .secret)
        #expect(model.credentialWarning == nil)
    }

    @Test func credentialKeyNameAloneWarns() async throws {
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let model = await editor(harness, id, mode: .add(.variable))
        model.name = "STRIPE_SECRET"
        model.value = "plain"
        let warning = try #require(model.credentialWarning)
        #expect(warning.reasons == [CredentialReason.keyContains("SECRET").editorExplanation])

        model.kind = .secret
        #expect(model.credentialWarning == nil, "secrets need no warning")
    }

    @Test func syncedVariableWarningOpensConvert() async throws {
        let (harness, id) = try await EditorFixtures.importedHarness()
        let variable = try await EditorFixtures.item(harness, id, named: "BASE_URL")
        let recorder = ActionRecorder()
        let model = await editor(harness, id, mode: .edit(variable.id), recorder: recorder)
        #expect(!model.isKindEditable)
        #expect(model.kindLockNote != nil)
        #expect(model.value == EditorFixtures.variableValue, "a variable opens with its plaintext value")

        model.value = EditorFixtures.urlWithCredentials
        #expect(model.credentialWarning?.action == .convertToSecret)
        model.resolveCredentialWarning()
        #expect(recorder.presented == [.itemEditor(ItemEditorContext(repositoryID: id, scope: .repository, mode: .move(variable.id)))])
        #expect(model.value.isEmpty, "leaving the sheet drops the typed value")
    }

    // MARK: - Edit

    @Test func editingASecretKeepsItsValueUnlessReplaced() async throws {
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let secret = try await EditorFixtures.item(harness, id, named: "API_TOKEN")
        let model = await editor(harness, id, mode: .edit(secret.id))
        #expect(model.title == "Edit API_TOKEN")
        #expect(model.value.isEmpty, "a secret is not decrypted until asked")
        #expect(model.keepsValueWhenEmpty)
        #expect(model.canLoadCurrentValue)
        #expect(model.isKindEditable, "not on GitHub yet")
        #expect(!model.canSave, "nothing changed")

        model.name = "api_key"
        #expect(model.canSave)
        #expect(model.save())
        let renamed = try await EditorFixtures.item(harness, id, named: "API_KEY")
        #expect(try EditorFixtures.revealed(harness, renamed.id) == EditorFixtures.secretValue)
    }

    @Test func editCurrentValueDecryptsOnRequestAndReplaces() async throws {
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let secret = try await EditorFixtures.item(harness, id, named: "API_TOKEN")
        let model = await editor(harness, id, mode: .edit(secret.id))
        model.loadCurrentValue()
        #expect(model.value == EditorFixtures.secretValue)
        #expect(!model.isValueEdited)
        #expect(!model.canSave)

        model.value = "FXV_FIXTURE_ROTATED"
        #expect(model.canSave)
        #expect(model.save())
        #expect(try EditorFixtures.revealed(harness, secret.id) == "FXV_FIXTURE_ROTATED")
    }

    @Test func clearingAVariableValueIsRefused() async throws {
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let variable = try await EditorFixtures.item(harness, id, named: "BASE_URL")
        let model = await editor(harness, id, mode: .edit(variable.id))
        model.value = ""
        #expect(model.valueNotes.contains { $0.isError })
        #expect(!model.canSave)
    }

    @Test func renamingASyncedItemExplainsTheRecreate() async throws {
        let (harness, id) = try await EditorFixtures.importedHarness()
        let variable = try await EditorFixtures.item(harness, id, named: "BASE_URL")
        let model = await editor(harness, id, mode: .edit(variable.id))
        model.name = "API_BASE_URL"
        #expect(model.nameNote?.tone == .info)
        #expect(model.nameNote?.message.contains("BASE_URL") == true)
        #expect(model.save())
        let renamed = try await EditorFixtures.item(harness, id, named: "API_BASE_URL")
        #expect(renamed.syncStatus == .added)
    }

    @Test func unsyncedSecretToVariableInEditAsksFirst() async throws {
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let secret = try await EditorFixtures.item(harness, id, named: "API_TOKEN")
        let model = await editor(harness, id, mode: .edit(secret.id))
        model.kind = .variable
        #expect(model.canSave)
        #expect(!model.save(), "a confirmation comes first")
        #expect(model.confirmation != nil)
        #expect(model.confirm())
        let converted = try await EditorFixtures.item(harness, id, named: "API_TOKEN")
        #expect(converted.kind == .variable)
        #expect(try EditorFixtures.revealed(harness, converted.id) == EditorFixtures.secretValue)
    }

    @Test func deletedItemsCannotBeEdited() async throws {
        let (harness, id) = try await EditorFixtures.importedHarness()
        let variable = try await EditorFixtures.item(harness, id, named: "BASE_URL")
        try harness.data.config.deleteItem(variable.id)
        let model = await editor(harness, id, mode: .edit(variable.id))
        #expect(model.loadState == .unavailable(ItemEditorError.deleted.errorPresentation))
        #expect(!model.canSave)
    }

    // MARK: - Fill (§7.1, §7.8)

    /// v0.1.2: the vault is the source of truth, so a filled value is pushed by default.
    @Test func fillPushesOnTheNextSyncByDefault() async throws {
        let (harness, id) = try await EditorFixtures.importedHarness()
        let secret = try await EditorFixtures.item(harness, id, named: "API_TOKEN")
        #expect(!secret.hasValue)
        let pendingBefore = try EditorFixtures.pendingCount(harness, id)
        let model = await editor(harness, id, mode: .fill(secret.id))
        #expect(model.isFilling)
        #expect(model.offersFillChoice)
        #expect(!model.fillMatchesGitHub, "Already matches GitHub (don't push) is off by default")
        #expect(!model.offersPushOnNextSync, "fill has its own choice")
        #expect(!model.isNameEditable)
        #expect(!model.canSave)

        model.value = EditorFixtures.secretValue
        #expect(model.primaryTitle == "Fill Value")
        #expect(model.save())
        let filled = try await EditorFixtures.item(harness, id, named: "API_TOKEN")
        #expect(filled.hasValue)
        #expect(filled.forcePush)
        #expect(filled.syncStatus == .modified)
        #expect(try EditorFixtures.pendingCount(harness, id) == pendingBefore + 1)
    }

    @Test func fillThatAlreadyMatchesGitHubPushesNothing() async throws {
        let (harness, id) = try await EditorFixtures.importedHarness()
        let secret = try await EditorFixtures.item(harness, id, named: "API_TOKEN")
        let pendingBefore = try EditorFixtures.pendingCount(harness, id)
        let model = await editor(harness, id, mode: .fill(secret.id))
        model.value = EditorFixtures.secretValue
        model.fillMatchesGitHub = true
        #expect(model.save())
        let filled = try await EditorFixtures.item(harness, id, named: "API_TOKEN")
        #expect(filled.hasValue)
        #expect(!filled.forcePush)
        #expect(filled.syncStatus == .synced)
        #expect(try EditorFixtures.pendingCount(harness, id) == pendingBefore, "nothing to push")
    }

    /// After a drift "Accept GitHub" the user chose GitHub's value: the editor starts with
    /// "Already matches GitHub" checked.
    @Test func fillAfterAcceptGitHubStartsAsMatchingGitHub() async throws {
        let (harness, id) = try await EditorFixtures.importedHarness()
        let secret = try await EditorFixtures.item(harness, id, named: "API_TOKEN")
        let model = ItemEditorViewModel(
            context: ItemEditorContext(repositoryID: id, scope: .repository, mode: .fill(secret.id), fillMatchesGitHub: true),
            dependencies: harness.dependencies(recorder: ActionRecorder())
        )
        await model.load()
        #expect(model.fillMatchesGitHub)
    }

    // MARK: - Push on Next Sync (v0.1.2)

    /// The imported `API_TOKEN` filled as "already matches GitHub": synced, with a value.
    private func syncedSecretWithValue(_ harness: TestHarness, _ id: RepoID) async throws -> ConfigItemModel {
        let secret = try await EditorFixtures.item(harness, id, named: "API_TOKEN")
        try harness.data.config.fillValue(secret.id, value: SecretBytes(utf8: EditorFixtures.secretValue), pushOnNextSync: false)
        let synced = try await EditorFixtures.item(harness, id, named: "API_TOKEN")
        #expect(synced.syncStatus == .synced && synced.hasValue)
        return synced
    }

    @Test func pushOnNextSyncResendsAnUnchangedSecret() async throws {
        let (harness, id) = try await EditorFixtures.importedHarness()
        let secret = try await syncedSecretWithValue(harness, id)
        let pendingBefore = try EditorFixtures.pendingCount(harness, id)
        let model = await editor(harness, id, mode: .edit(secret.id))
        #expect(model.offersPushOnNextSync)
        #expect(!model.pushOnNextSync, "off by default")
        #expect(!model.canSave, "nothing changed yet")

        model.pushOnNextSync = true
        #expect(model.canSave)
        #expect(model.save())

        let marked = try await EditorFixtures.item(harness, id, named: "API_TOKEN")
        #expect(marked.forcePush)
        #expect(marked.syncStatus == .willPush)
        #expect(try harness.data.config.reveal(marked.id).utf8String() == EditorFixtures.secretValue, "value kept")
        #expect(try EditorFixtures.pendingCount(harness, id) == pendingBefore + 1)

        let reopened = await editor(harness, id, mode: .edit(secret.id))
        #expect(!reopened.offersPushOnNextSync)
        #expect(reopened.isPushAlreadyRequested)
    }

    @Test func pushOnNextSyncIsOnlyOfferedForSyncedSecretsWithAValue() async throws {
        let (harness, id) = try await EditorFixtures.importedHarness()
        let variable = try await EditorFixtures.item(harness, id, named: "BASE_URL")
        let variableEditor = await editor(harness, id, mode: .edit(variable.id))
        #expect(!variableEditor.offersPushOnNextSync, "variables are compared by value")

        let (staged, stagedID) = try await EditorFixtures.stagedHarness()
        let unsynced = try await EditorFixtures.item(staged, stagedID, named: "API_TOKEN")
        let unsyncedEditor = await editor(staged, stagedID, mode: .edit(unsynced.id))
        #expect(!unsyncedEditor.offersPushOnNextSync, "not on GitHub yet: Sync adds it anyway")
    }

    @Test func aRenameWithPushOnNextSyncIsJustARename() async throws {
        let (harness, id) = try await EditorFixtures.importedHarness()
        let secret = try await syncedSecretWithValue(harness, id)
        let model = await editor(harness, id, mode: .edit(secret.id))
        model.pushOnNextSync = true
        model.name = "API_TOKEN_V2"
        #expect(model.save())
        let renamed = try await EditorFixtures.item(harness, id, named: "API_TOKEN_V2")
        #expect(!renamed.forcePush)
        #expect(renamed.syncStatus == .added, "the rename creates the new name on GitHub")
    }

    @Test func fillOfASecretWithAValueIsUnavailable() async throws {
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let secret = try await EditorFixtures.item(harness, id, named: "API_TOKEN")
        let model = await editor(harness, id, mode: .fill(secret.id))
        #expect(model.loadState == .unavailable(ConfigRepositoryError.edit(.valueNotMissing).presentation))
    }

    // MARK: - Convert / Move (D11)

    @Test func convertSecretToVariableNeedsConfirmationWithCancelAsDefault() async throws {
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let secret = try await EditorFixtures.item(harness, id, named: "API_TOKEN")
        let model = await editor(harness, id, mode: .move(secret.id))
        #expect(model.targetKind == .variable, "Convert is preselected")
        #expect(model.targetScope == .repository)
        #expect(model.primaryTitle == "Convert")
        #expect(model.canSave)

        #expect(!model.save())
        let confirmation = try #require(model.confirmation)
        #expect(confirmation.confirmTitle == "Convert to Variable")
        for text in visibleText(model) {
            #expect(!text.contains(EditorFixtures.secretValue))
        }

        // Cancel (the default button) leaves everything as it was.
        model.cancelConfirmation()
        #expect(model.confirmation == nil)
        #expect(try await EditorFixtures.item(harness, id, named: "API_TOKEN").kind == .secret)

        #expect(!model.save())
        #expect(model.confirm())
        let converted = try await EditorFixtures.item(harness, id, named: "API_TOKEN")
        #expect(converted.kind == .variable)
    }

    @Test func moveToAnotherScopeNeedsNoConfirmation() async throws {
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let secret = try await EditorFixtures.item(harness, id, named: "API_TOKEN")
        let staging = try EditorFixtures.environment(harness, id, named: "staging")
        let model = await editor(harness, id, mode: .move(secret.id))
        model.targetKind = .secret
        #expect(!model.canSave, "same kind and scope")
        model.targetScope = .environment(staging.id)
        #expect(model.primaryTitle == "Move")
        #expect(model.moveNotes.map(\.message) == ["It is not on GitHub yet, so it simply moves."])
        #expect(model.save())
        #expect(model.confirmation == nil)
        let moved = try await EditorFixtures.item(harness, id, named: "API_TOKEN", scope: .environment(staging.id))
        #expect(try EditorFixtures.revealed(harness, moved.id) == EditorFixtures.secretValue)
    }

    @Test func valueMissingSecretCanOnlyMoveAsASecret() async throws {
        let (harness, id) = try await EditorFixtures.importedHarness()
        let production = try EditorFixtures.environment(harness, id, named: "production")
        let secret = try await EditorFixtures.item(harness, id, named: "DEPLOY_KEY", scope: .environment(production.id))
        let model = await editor(harness, id, scope: .environment(production.id), mode: .move(secret.id))
        #expect(model.targetKind == .secret)
        #expect(!model.canMove(to: ConfigKind.variable))
        #expect(model.moveNotes.count == 1)
        #expect(model.moveNotes.first?.message.contains("DEPLOY_KEY") == true)

        model.targetScope = .repository
        #expect(model.moveNotes.last?.message.contains("deletes it from production") == true)
        #expect(model.save())
        let moved = try await EditorFixtures.item(harness, id, named: "DEPLOY_KEY")
        #expect(!moved.hasValue)
        #expect(moved.syncStatus == .blocked)
    }

    // MARK: - Capability and lock

    @Test func readOnlyRepositoriesCannotBeEdited() async throws {
        let (harness, id) = try await EditorFixtures.importedHarness(permission: "WRITE")
        let model = await editor(harness, id, mode: .add(.secret))
        #expect(model.readOnlyReason == .adminRequired)
        model.name = "NEW_SECRET"
        model.value = "v"
        #expect(!model.canSave)
        #expect(!model.save())
    }

    @Test func lockDropsTheTypedValue() async throws {
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let secret = try await EditorFixtures.item(harness, id, named: "API_TOKEN")
        let model = await editor(harness, id, mode: .edit(secret.id))
        model.loadCurrentValue()
        model.kind = .variable
        _ = model.save()
        #expect(model.confirmation != nil)
        #expect(model.value == EditorFixtures.secretValue)

        harness.app.lock(trigger: .manual)
        #expect(model.value.isEmpty)
        #expect(model.confirmation == nil)
        #expect(!model.isCurrentValueLoaded)
    }

    @Test func savingWhileLockedShowsAnErrorWithoutTheValue() async throws {
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let model = await editor(harness, id, mode: .add(.secret))
        model.name = "LATE_SECRET"
        model.value = EditorFixtures.secretValue
        harness.vaultManager.lock()
        #expect(!model.save())
        let alert = try #require(model.alert)
        #expect(!alert.message.contains(EditorFixtures.secretValue))
        #expect(!alert.title.contains(EditorFixtures.secretValue))
    }
}
