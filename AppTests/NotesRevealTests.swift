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

        detail.notesReveal.ask(line)
        detail.notesReveal.reauth?.password = testPassword
        await detail.notesReveal.authenticateWithPassword()
        #expect(detail.notes.items.first?.value == .revealed(EditorFixtures.secretValue))

        harness.app.lock(trigger: .manual)
        #expect(detail.notes.items.first?.value == .masked)
    }

    /// The toolbar's "Hidden from screen capture" follows the open place, and resign active
    /// masks it.
    @Test func theWindowKnowsWhenAValueShows() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: MainViewModelTests.ready)
        let main = harness.app.makeMainViewModel()
        #expect(main.placeViewMode == .notes)
        let id = try await harness.stageRepository(items: [TestFixtures.item(.secret, "API_TOKEN", RepoDetailViewModelTests.secretValue)])
        let detail = try await MainConnectivityTests.open(id, in: main)
        #expect(await TestFixtures.eventually { !detail.rows.isEmpty })
        let row = try #require(detail.rows.first)
        #expect(!main.isShowingRevealedValue)

        detail.reveal(row.id)
        #expect(main.isShowingRevealedValue)
        main.remaskRevealedValues()
        #expect(!main.isShowingRevealedValue)
    }
}
