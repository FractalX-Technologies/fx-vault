import AppKit
import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Reveal in a place's notes (1.0 B9; board Place-Reveal): "Confirm it's you" first, then one
/// secret shows until it hides again after `Timeouts.revealRemask`.
@MainActor
@Suite("Reveal in the notes")
struct NotesRevealTests {
    static func secretLine(_ model: RepoDetailViewModel) async throws -> NotesItemLineModel {
        #expect(await TestFixtures.eventually { model.items.count == 2 })
        return try #require(model.notes.items.first { $0.kind == .secret })
    }

    static func value(_ model: RepoDetailViewModel) -> ConfigValueDisplayModel? {
        model.notes.items.first { $0.kind == .secret }?.value
    }

    /// Nothing shows before the gate says yes; a wrong password shows nothing.
    @Test func asksTheGateFirstThenShowsTheValueUntilItHides() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let (harness, model) = (fixture.harness, fixture.viewModel)
        let reveal = model.notesReveal
        let line = try await Self.secretLine(model)

        reveal.ask(line)
        #expect(reveal.request == NotesRevealRequestModel(id: line.id, name: "API_TOKEN"))
        await reveal.start()
        #expect(reveal.request != nil, "Touch ID is off: the password field waits")
        #expect(Self.value(model) == .masked)

        reveal.reauth?.password = otherTestPassword
        await reveal.authenticateWithPassword()
        #expect(reveal.reauth?.error != nil)
        #expect(Self.value(model) == .masked)

        let sleepersBefore = harness.clock.sleeperCount
        reveal.reauth?.password = testPassword
        await reveal.authenticateWithPassword()
        #expect(reveal.request == nil)
        #expect(reveal.reauth == nil, "the typed password goes with the sheet")
        #expect(Self.value(model) == .revealed(RepoDetailViewModelTests.secretValue))
        #expect(reveal.hideDate(of: line.id) == harness.clock.now.addingTimeInterval(Timeouts.revealRemask.timeInterval))

        await harness.clock.waitForSleepers(count: sleepersBefore + 1)
        harness.clock.advance(by: Timeouts.revealRemask)
        await model.remaskTasks[line.id]?.value
        #expect(Self.value(model) == .masked)
        #expect(reveal.hideDate(of: line.id) == nil)
    }

    /// Secrets whose values were just pasted or typed in the editor show after Save without
    /// asking (the user had them on screen), then hide again on the usual timer; the others
    /// stay masked.
    @Test func savedValuesShowAfterTheEditUntilTheyHide() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let (harness, model) = (fixture.harness, fixture.viewModel)
        _ = try await Self.secretLine(model)
        model.beginNotesEdit(at: nil)
        let (session, view) = try NotesEditSessionTests.editor(model)
        let pasteboard = NotesEditorTests.pasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("key1=secret1\nkey2=secret2\n", forType: .string)
        view.setSelectedRange(NSRange(location: NSMaxRange((view.string as NSString).range(of: "API_TOKEN = ")) + 1, length: 0))
        NotesEditorTests.type("\n", in: view)
        #expect(view.readSelection(from: pasteboard, type: .string))

        let sleepersBefore = harness.clock.sleeperCount
        session.requestReview()
        session.save()
        #expect(await TestFixtures.eventually {
            model.notes.items.first { $0.name == "KEY2" }?.value == .revealed("secret2")
        })
        let key1 = try #require(model.notes.items.first { $0.name == "KEY1" })
        #expect(key1.value == .revealed("secret1"))
        #expect(model.notesReveal.request == nil, "nothing asked")
        #expect(Self.value(model) == .masked, "API_TOKEN was not edited")
        #expect(model.notesReveal.hideDate(of: key1.id) == harness.clock.now.addingTimeInterval(Timeouts.revealRemask.timeInterval))

        await harness.clock.waitForSleepers(count: sleepersBefore + 2)
        harness.clock.advance(by: Timeouts.revealRemask)
        await model.remaskTasks[key1.id]?.value
        #expect(model.notes.items.first { $0.name == "KEY1" }?.value == .masked)
    }

    /// With Touch ID on, the sheet asks once when it appears and reveals on success.
    @Test func touchIDRevealsWhenTheSheetAppears() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let harness = fixture.harness
        try await harness.enableTouchID()
        let loadsBefore = harness.biometrics.loadCount
        let model = fixture.viewModel
        let line = try await Self.secretLine(model)

        model.notesReveal.ask(line)
        await model.notesReveal.start()
        #expect(harness.biometrics.loadCount == loadsBefore + 1)
        #expect(Self.value(model) == .revealed(RepoDetailViewModelTests.secretValue))

        // A revealed line asks nothing more; Hide masks it at once.
        model.notesReveal.ask(line)
        #expect(model.notesReveal.request == nil)
        model.notesReveal.hide(line.id)
        #expect(Self.value(model) == .masked)
    }

    @Test func cancelLockAndAnotherScopeDropTheRequest() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let model = fixture.viewModel
        let reveal = model.notesReveal
        let line = try await Self.secretLine(model)

        reveal.ask(line)
        reveal.reauth?.password = otherTestPassword
        reveal.cancel()
        #expect(reveal.request == nil)
        #expect(reveal.reauth == nil)

        reveal.ask(line)
        try fixture.harness.data.config.createEnvironment(in: fixture.repositoryID, name: "production")
        let production = try EditorFixtures.environment(fixture.harness, fixture.repositoryID, named: "production")
        model.select(scope: .environment(production.id))
        #expect(reveal.request == nil)

        model.select(scope: .repository)
        _ = try await Self.secretLine(model)
        reveal.ask(line)
        fixture.harness.app.lock(trigger: .manual)
        #expect(reveal.request == nil)
        #expect(reveal.reauth == nil)
    }

    /// A check that ends after its request was replaced, or after a lock, reveals nothing: the
    /// new request waits for its own check.
    @Test func aCheckThatEndsTooLateRevealsNothing() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let harness = fixture.harness
        try await harness.enableTouchID()
        let model = fixture.viewModel
        let reveal = model.notesReveal
        let line = try await Self.secretLine(model)

        // Touch ID is "up" until the gate opens; meanwhile Cancel, then Reveal again.
        let firstPrompt = CallGate()
        harness.biometrics.onNextLoad { firstPrompt.wait() }
        reveal.ask(line)
        let first = Task { await reveal.start() }
        #expect(await TestFixtures.eventually { reveal.reauth?.isAuthorizing == true })
        reveal.cancel()
        reveal.ask(line)
        firstPrompt.open()
        await first.value
        #expect(Self.value(model) == .masked)
        #expect(reveal.request != nil, "the new request still waits for its own check")
        #expect(reveal.reauth?.isAuthorized == false)

        // The new request's check, with a lock while Touch ID is up.
        let secondPrompt = CallGate()
        harness.biometrics.onNextLoad { secondPrompt.wait() }
        let second = Task { await reveal.start() }
        #expect(await TestFixtures.eventually { reveal.reauth?.isAuthorizing == true })
        harness.app.lock(trigger: .manual)
        secondPrompt.open()
        await second.value
        #expect(Self.value(model) == .masked)
        #expect(reveal.request == nil)
    }

    /// Reveal All (board Place-Reveal): one "Confirm it's you" shows every secret of the place
    /// under one countdown; a click copies at once while they show, and they hide together.
    @Test func revealAllAsksOnceThenShowsEverySecretUntilTheyHideTogether() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture(
            items: RepoDetailViewModelTests.Fixture.items + [TestFixtures.item(.secret, "DB_PASSWORD", Self.otherSecret)]
        )
        let (harness, model) = (fixture.harness, fixture.viewModel)
        let reveal = model.notesReveal
        #expect(await TestFixtures.eventually { model.items.count == 3 })
        let secrets = model.notes.items.filter { $0.kind == .secret }

        reveal.toggleRevealAll(model.notes, place: model.notesPlaceName)
        #expect(reveal.request?.action == .revealAll(secrets.map(\.id)))
        #expect(!reveal.isRevealingAll)
        #expect(Self.value(of: "API_TOKEN", in: model) == .masked)

        let sleepersBefore = harness.clock.sleeperCount
        await TableRevealTests.confirm(reveal)
        #expect(reveal.request == nil)
        #expect(Self.value(of: "API_TOKEN", in: model) == .revealed(RepoDetailViewModelTests.secretValue))
        #expect(Self.value(of: "DB_PASSWORD", in: model) == .revealed(Self.otherSecret))
        #expect(reveal.revealAllHideDate == harness.clock.now.addingTimeInterval(Timeouts.revealAllRemask.timeInterval))
        #expect(secrets.allSatisfy { reveal.hideDate(of: $0.id) == nil }, "one countdown for all, none per line")

        // A shown secret copies at once: no second "Confirm it's you".
        model.copy(try #require(secrets.last).id)
        #expect(reveal.request == nil)
        #expect(harness.pasteboardString == Self.otherSecret)
        #expect(reveal.copiedID == secrets.last?.id, "its line says Copied")

        await harness.clock.waitForSleepers(count: sleepersBefore + 1)
        harness.clock.advance(by: Timeouts.revealAllRemask)
        await model.values.revealAllTask?.value
        #expect(Self.value(of: "API_TOKEN", in: model) == .masked)
        #expect(Self.value(of: "DB_PASSWORD", in: model) == .masked)
        #expect(!reveal.isRevealingAll)
        #expect(reveal.revealAllHideDate == nil)
    }

    /// Hide All, another scope and a lock mask every secret Reveal All showed.
    @Test func hideAllLockAndAnotherScopeEndRevealAll() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let model = fixture.viewModel
        let reveal = model.notesReveal
        let line = try await Self.secretLine(model)

        reveal.toggleRevealAll(model.notes, place: model.notesPlaceName)
        await TableRevealTests.confirm(reveal)
        #expect(reveal.isRevealingAll)
        model.copy(line.id)
        #expect(reveal.copiedID == line.id)
        reveal.toggleRevealAll(model.notes, place: model.notesPlaceName)
        #expect(!reveal.isRevealingAll)
        #expect(reveal.request == nil, "Hide All asks nothing")
        #expect(Self.value(model) == .masked)

        try fixture.harness.data.config.createEnvironment(in: fixture.repositoryID, name: "production")
        let production = try EditorFixtures.environment(fixture.harness, fixture.repositoryID, named: "production")
        reveal.toggleRevealAll(model.notes, place: model.notesPlaceName)
        await TableRevealTests.confirm(reveal)
        #expect(reveal.isRevealingAll)
        #expect(reveal.copiedID == nil, "a new Reveal All forgets the earlier copy")
        model.select(scope: .environment(production.id))
        #expect(!reveal.isRevealingAll)
        model.select(scope: .repository)
        _ = try await Self.secretLine(model)

        reveal.toggleRevealAll(model.notes, place: model.notesPlaceName)
        await TableRevealTests.confirm(reveal)
        #expect(Self.value(model) == .revealed(RepoDetailViewModelTests.secretValue))
        fixture.harness.app.lock(trigger: .manual)
        #expect(!reveal.isRevealingAll)
        #expect(Self.value(model) == .masked)
    }

    /// A lock while Reveal All's "Confirm it's you" is up drops it: nothing shows.
    @Test func aLockDuringRevealAllsCheckRevealsNothing() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let model = fixture.viewModel
        let reveal = model.notesReveal
        _ = try await Self.secretLine(model)

        reveal.toggleRevealAll(model.notes, place: model.notesPlaceName)
        await reveal.start()
        reveal.reauth?.password = testPassword
        fixture.harness.app.lock(trigger: .manual)
        await reveal.authenticateWithPassword()
        #expect(reveal.request == nil)
        #expect(!reveal.isRevealingAll)
        #expect(Self.value(model) == .masked)
    }

    /// One secret that can't be decrypted reveals none (all or nothing) and says why; a value
    /// revealed on its own before keeps showing with its own countdown.
    @Test func aFailedDecryptRevealsNoneOfTheSecrets() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture(
            items: RepoDetailViewModelTests.Fixture.items + [TestFixtures.item(.secret, "DB_PASSWORD", Self.otherSecret)]
        )
        let (harness, model) = (fixture.harness, fixture.viewModel)
        #expect(await TestFixtures.eventually { model.items.count == 3 })
        let first = try #require(model.notes.items.first { $0.name == "API_TOKEN" })
        let broken = try #require(model.notes.items.first { $0.name == "DB_PASSWORD" })
        let values = ConfigValueRevealer(clock: harness.clock) { id throws(ConfigRepositoryError) in
            guard id != broken.id else { throw .unexpected }
            return SecretBytes(utf8: RepoDetailViewModelTests.secretValue)
        }
        let reveal = NotesRevealModel(values: values, dependencies: harness.dependencies(recorder: ActionRecorder()))
        try values.reveal(first.id)

        reveal.toggleRevealAll(model.notes, place: model.notesPlaceName)
        await TableRevealTests.confirm(reveal)
        #expect(reveal.alert != nil)
        #expect(!reveal.isRevealingAll)
        #expect(values.revealAllTask == nil)
        #expect(!values.isRevealed(broken.id))
        #expect(Set(values.revealedValues.keys) == [first.id], "only the earlier single reveal shows")
        #expect(reveal.hideDate(of: first.id) != nil, "and it keeps its own countdown")
    }

    /// A secret revealed on its own joins Reveal All's countdown; one hidden on its own leaves
    /// the others showing.
    @Test func revealAllTakesOverASingleRevealAndHidesOneByOne() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture(
            items: RepoDetailViewModelTests.Fixture.items + [TestFixtures.item(.secret, "DB_PASSWORD", Self.otherSecret)]
        )
        let model = fixture.viewModel
        let reveal = model.notesReveal
        #expect(await TestFixtures.eventually { model.items.count == 3 })
        let first = try #require(model.notes.items.first { $0.name == "API_TOKEN" })

        reveal.ask(first)
        await TableRevealTests.confirm(reveal)
        #expect(reveal.hideDate(of: first.id) != nil)
        reveal.toggleRevealAll(model.notes, place: model.notesPlaceName)
        await TableRevealTests.confirm(reveal)
        #expect(reveal.hideDate(of: first.id) == nil)
        #expect(model.remaskTasks[first.id] == nil, "its own re-mask is gone")

        reveal.hide(first.id)
        #expect(reveal.isRevealingAll)
        #expect(Self.value(of: "DB_PASSWORD", in: model) == .revealed(Self.otherSecret))
        let second = try #require(model.notes.items.first { $0.name == "DB_PASSWORD" })
        reveal.hide(second.id)
        #expect(!reveal.isRevealingAll, "the last one hidden ends Reveal All")
    }

    /// Every other path that masks a value ends Reveal All too: an edit of the notes and the
    /// app resigning active (which keeps the window out of screen capture meanwhile).
    @Test func anEditAndResignActiveEndRevealAll() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let model = fixture.viewModel
        let line = try await Self.secretLine(model)

        try model.values.revealAll([line.id])
        model.beginNotesEdit(at: nil)
        #expect(!model.notesReveal.isRevealingAll)
        #expect(Self.value(model) == .masked)

        let main = fixture.harness.app.makeMainViewModel()
        let repository = try await MainConnectivityTests.open(fixture.repositoryID, in: main)
        #expect(await TestFixtures.eventually { !repository.rows.isEmpty })
        let id = try #require(repository.items.first { $0.kind == .secret }?.id)
        try repository.values.revealAll([id])
        #expect(main.isShowingRevealedValue)
        main.remaskRevealedValues()
        #expect(!repository.notesReveal.isRevealingAll)
        #expect(!main.isShowingRevealedValue)
    }

    /// Under Reveal All a secret that doesn't show (hidden on its own) still asks before its
    /// copy, and a copy that fails never says Copied.
    @Test func aMaskedSecretStillAsksAndAFailedCopyIsNotCopied() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture(
            items: RepoDetailViewModelTests.Fixture.items + [TestFixtures.item(.secret, "DB_PASSWORD", Self.otherSecret)]
        )
        let model = fixture.viewModel
        let reveal = model.notesReveal
        #expect(await TestFixtures.eventually { model.items.count == 3 })
        #expect(reveal.canToggleRevealAll(model.notes))
        let first = try #require(model.notes.items.first { $0.name == "API_TOKEN" })

        reveal.toggleRevealAll(model.notes, place: model.notesPlaceName)
        await TableRevealTests.confirm(reveal)
        reveal.hide(first.id)
        #expect(reveal.isRevealingAll)
        model.copy(first.id)
        #expect(reveal.request?.action == .copy)
        #expect(fixture.harness.pasteboardString == nil)
        reveal.cancel()

        reveal.copy(first.id, name: first.name, kind: .variable) { _ in false }
        #expect(reveal.copiedID == nil)
    }

    /// Nothing to reveal (no secret with a value here) asks nothing.
    @Test func revealAllWithoutSecretsAsksNothing() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture(items: [
            TestFixtures.item(.variable, "BASE_URL", RepoDetailViewModelTests.variableValue),
        ])
        let model = fixture.viewModel
        #expect(await TestFixtures.eventually { model.items.count == 1 })
        #expect(!NotesRevealModel.canRevealAll(model.notes))
        #expect(!model.notesReveal.canToggleRevealAll(model.notes), "the header's Reveal All is disabled")
        model.notesReveal.toggleRevealAll(model.notes, place: model.notesPlaceName)
        #expect(model.notesReveal.request == nil)
    }

    static let otherSecret = "FXV_FIXTURE_OTHER_SECRET"

    static func value(of name: String, in model: RepoDetailViewModel) -> ConfigValueDisplayModel? {
        model.notes.items.first { $0.name == name }?.value
    }

    /// An organization's own secret reveals through the organization's items.
    @Test func anOrganizationsSecretRevealsToo() async throws {
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
        #expect(await TestFixtures.eventually { detail.notes.items.contains { $0.name == "API_TOKEN" } })
        let line = try #require(detail.notes.items.first { $0.name == "API_TOKEN" })

        #expect(await TestFixtures.eventually { Self.value(of: "REGION", in: detail) == .plain("eu-west") })

        detail.notesReveal.ask(line)
        detail.notesReveal.reauth?.password = testPassword
        await detail.notesReveal.authenticateWithPassword()
        #expect(Self.value(of: "API_TOKEN", in: detail) == .revealed(EditorFixtures.secretValue))

        // A lock masks the secret and drops the variables decrypted for the notes.
        harness.app.lock(trigger: .manual)
        #expect(Self.value(of: "API_TOKEN", in: detail) == .masked)
        #expect(Self.value(of: "REGION", in: detail) == .masked)
    }

    static func value(of name: String, in detail: OrganizationDetailViewModel) -> ConfigValueDisplayModel? {
        detail.notes.items.first { $0.name == name }?.value
    }

    /// The toolbar's "Hidden from screen capture" follows whichever place is open, and resign
    /// active masks it: a repository scope, a folder, a Key Vault and an organization.
    @Test func theWindowKnowsWhenAValueShowsInEveryPlace() async throws {
        let (harness, organization) = try await OrganizationEditingTests().imported()
        _ = try harness.data.organizationItems.addItem(
            organizationID: organization.id,
            kind: .secret,
            name: "API_TOKEN",
            value: SecretBytes(utf8: EditorFixtures.secretValue),
            access: .all
        )
        let folderID = try harness.data.folders.createFolder(named: "Mobile App")
        try harness.data.folders.addItem(folderID: folderID, kind: .secret, name: "FIREBASE_API_KEY", value: SecretBytes(utf8: EditorFixtures.secretValue))
        let vaultID = try harness.data.destinations.createDestination(
            repositoryID: nil,
            target: .azureKeyVault(vaultName: "kv-example-prod", tenantID: nil),
            stage: nil
        )
        try harness.data.destinations.addItem(destinationID: vaultID, kind: .secret, name: "API_KEY", value: SecretBytes(utf8: EditorFixtures.secretValue))
        let repositoryID = try await harness.stageRepository(items: [TestFixtures.item(.secret, "API_TOKEN", RepoDetailViewModelTests.secretValue)])
        let main = harness.app.makeMainViewModel()
        #expect(main.placeViewMode == .notes)

        let repository = try await MainConnectivityTests.open(repositoryID, in: main)
        try await Self.expectTheWindowFollows(repository.values, in: main) { repository.rows.first?.id }
        // An edit can draw a value set in it: the window stays out of capture while it runs.
        repository.beginNotesEdit(at: nil)
        #expect(main.isShowingRevealedValue)
        repository.notesEdit?.cancel()
        #expect(!main.isShowingRevealedValue)

        main.sidebar.selectedFolderID = folderID
        let folder = try #require(main.folderDetail)
        try await Self.expectTheWindowFollows(folder.values, in: main) { folder.rows.first?.id }

        #expect(await TestFixtures.eventually { main.sidebar.keyVaults.map(\.id) == [vaultID] })
        main.sidebar.selectedKeyVaultID = vaultID
        let vault = try #require(main.destinationDetail)
        try await Self.expectTheWindowFollows(vault.values, in: main) { vault.rows.first?.id }

        main.sidebar.select(organization: OrganizationViewModelTests.owner())
        #expect(await TestFixtures.eventually { main.organizationDetail != nil })
        let detail = try #require(main.organizationDetail)
        try await Self.expectTheWindowFollows(detail.values, in: main) {
            detail.items.first { $0.name == "API_TOKEN" }?.id
        }
    }

    /// Reveals the place's secret: the window knows, and `remaskRevealedValues()` masks it.
    static func expectTheWindowFollows(
        _ values: ConfigValueRevealer,
        in main: MainViewModel,
        secret: @MainActor () -> ConfigItemID?
    ) async throws {
        #expect(await TestFixtures.eventually { secret() != nil })
        let id = try #require(secret())
        #expect(!main.isShowingRevealedValue)
        try values.reveal(id)
        #expect(main.isShowingRevealedValue)
        main.remaskRevealedValues()
        #expect(!main.isShowingRevealedValue)
        #expect(!values.isRevealed(id))
    }
}
