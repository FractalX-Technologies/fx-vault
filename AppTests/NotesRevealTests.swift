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
