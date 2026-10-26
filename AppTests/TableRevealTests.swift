import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// The table's eye and Copy Value on a secret (1.0 T1): "Confirm it's you" first, as Reveal in
/// the notes, once per click; variables copy at once and inherited secrets never show.
@MainActor
@Suite("Reveal and copy in the table")
struct TableRevealTests {
    /// Answers "Confirm it's you" with the master password (Touch ID is off in the harness).
    static func confirm(_ reveal: NotesRevealModel, password: String = testPassword) async {
        await reveal.start()
        reveal.reauth?.password = password
        await reveal.authenticateWithPassword()
    }

    @Test func theEyeShowsNothingUntilTheGateSaysYesAndAsksAgainOnceMasked() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let model = fixture.viewModel
        let secret = try await fixture.secretRow()

        model.toggleReveal(secret.id)
        #expect(model.notesReveal.request == NotesRevealRequestModel(id: secret.id, name: "API_TOKEN"))
        #expect(model.display(for: secret) == .masked)
        await Self.confirm(model.notesReveal, password: otherTestPassword)
        #expect(model.display(for: secret) == .masked, "a wrong password shows nothing")

        model.notesReveal.reauth?.password = testPassword
        await model.notesReveal.authenticateWithPassword()
        #expect(model.display(for: secret) == .revealed(RepoDetailViewModelTests.secretValue))

        // The eye hides at once; the next reveal asks again.
        model.toggleReveal(secret.id)
        #expect(model.display(for: secret) == .masked)
        model.toggleReveal(secret.id)
        #expect(model.notesReveal.request != nil)
        #expect(model.display(for: secret) == .masked)
    }

    @Test func copyValueOfASecretCopiesNothingUntilTheGateSaysYes() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let (harness, model) = (fixture.harness, fixture.viewModel)
        let secret = try await fixture.secretRow()

        model.copy(secret.id)
        #expect(model.notesReveal.request == NotesRevealRequestModel(id: secret.id, name: "API_TOKEN", action: .copy))
        #expect(harness.pasteboardString == nil)
        await Self.confirm(model.notesReveal)
        #expect(harness.pasteboardString == RepoDetailViewModelTests.secretValue)
        #expect(!model.isRevealed(secret.id), "a copy shows nothing")

        // One yes per click: the next Copy asks again.
        harness.container.clipboard.clearIfOwned()
        model.copy(secret.id)
        #expect(model.notesReveal.request?.action == .copy)
        #expect(harness.pasteboardString == nil)

        // A variable copies at once.
        model.notesReveal.cancel()
        model.kind = .variable
        let variable = try #require(model.rows.first)
        model.copy(variable.id)
        #expect(model.notesReveal.request == nil)
        #expect(harness.pasteboardString == RepoDetailViewModelTests.variableValue)
    }

    /// A secret that shows copies at once: its value is on screen already.
    @Test func aSecretThatShowsCopiesAtOnce() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let model = fixture.viewModel
        let secret = try await fixture.secretRow()
        model.toggleReveal(secret.id)
        await Self.confirm(model.notesReveal)

        model.copy(secret.id)
        #expect(model.notesReveal.request == nil)
        #expect(fixture.harness.pasteboardString == RepoDetailViewModelTests.secretValue)
    }

    /// A lock or another scope drops the request; a Touch ID result that ends after the lock
    /// copies nothing.
    @Test func aLockOrAnotherScopeDropsThePendingRequest() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let harness = fixture.harness
        let model = fixture.viewModel
        let secret = try await fixture.secretRow()

        model.copy(secret.id)
        try harness.data.config.createEnvironment(in: fixture.repositoryID, name: "production")
        let production = try EditorFixtures.environment(harness, fixture.repositoryID, named: "production")
        model.select(scope: .environment(production.id))
        #expect(model.notesReveal.request == nil)

        model.select(scope: .repository)
        let again = try await fixture.secretRow()
        model.toggleReveal(again.id)
        harness.app.lock(trigger: .manual)
        #expect(model.notesReveal.request == nil)
        #expect(model.notesReveal.reauth == nil)
    }

    /// What drops a request while Touch ID is still up.
    enum Drop: CaseIterable {
        case lock
        case scope
    }

    @Test(arguments: Drop.allCases)
    func aTouchIDResultAfterALockOrAnotherScopeCopiesNothing(_ drop: Drop) async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let harness = fixture.harness
        try await harness.enableTouchID()
        try harness.data.config.createEnvironment(in: fixture.repositoryID, name: "production")
        let production = try EditorFixtures.environment(harness, fixture.repositoryID, named: "production")
        let model = fixture.viewModel
        let secret = try await fixture.secretRow()

        let prompt = CallGate()
        harness.biometrics.onNextLoad { prompt.wait() }
        model.copy(secret.id)
        let check = Task { await model.notesReveal.start() }
        #expect(await TestFixtures.eventually { model.notesReveal.reauth?.isAuthorizing == true })
        switch drop {
        case .lock: harness.app.lock(trigger: .manual)
        case .scope: model.select(scope: .environment(production.id))
        }
        prompt.open()
        await check.value
        #expect(harness.pasteboardString == nil)
        #expect(model.notesReveal.request == nil)
    }

    /// An organization's secret a repository gets never shows in its table, and asks nothing.
    @Test func anInheritedSecretNeverShows() async throws {
        let fixture = try await RepoDetailInheritedTests.fixture()
        let model = fixture.model
        #expect(await TestFixtures.eventually { model.tableRows.contains { $0.name == "NPM_TOKEN" } })
        let inherited = try #require(model.tableRows.first { $0.name == "NPM_TOKEN" })
        #expect(inherited.inherited != nil)

        model.toggleReveal(inherited.id)
        model.copy(inherited.id)
        #expect(model.notesReveal.request == nil)
        #expect(!model.isRevealed(inherited.id))
        #expect(fixture.harness.pasteboardString == nil)
    }

    /// A folder, a Key Vault and an organization ask the same way.
    @Test func everyPlacesTableAsksFirst() async throws {
        let folderFixture = try await FolderViewModelTests.Fixture()
        let folder = folderFixture.folder
        #expect(await folderFixture.waitForFolderRows(["FIREBASE_API_KEY"]))
        let folderRow = try #require(folder.rows.first)
        folder.toggleReveal(folderRow.id)
        #expect(folder.display(for: folderRow) == .masked)
        await Self.confirm(folder.notesReveal)
        #expect(folder.display(for: folderRow) == .revealed(EditorFixtures.secretValue))

        let harness = try await TestHarness(vault: .unlocked)
        let vaultID = try harness.data.destinations.createDestination(
            repositoryID: nil,
            target: .azureKeyVault(vaultName: "kv-example-prod", tenantID: nil),
            stage: nil
        )
        try harness.data.destinations.addItem(destinationID: vaultID, kind: .secret, name: "API_TOKEN", value: SecretBytes(utf8: EditorFixtures.secretValue))
        let vault = DestinationDetailViewModel(
            destination: try #require(try harness.data.destinations.destination(vaultID)),
            dependencies: harness.dependencies(recorder: ActionRecorder())
        ) {
            try? harness.data.destinations.destination(vaultID)
        }
        #expect(await TestFixtures.eventually { !vault.rows.isEmpty })
        let vaultRow = try #require(vault.rows.first)
        vault.copy(vaultRow.id)
        #expect(harness.pasteboardString == nil)
        await Self.confirm(vault.notesReveal)
        #expect(harness.pasteboardString == EditorFixtures.secretValue)

        let (orgHarness, organization) = try await OrganizationEditingTests().imported()
        _ = try orgHarness.data.organizationItems.addItem(
            organizationID: organization.id,
            kind: .secret,
            name: "API_TOKEN",
            value: SecretBytes(utf8: EditorFixtures.secretValue),
            access: .all
        )
        let org = OrganizationDetailViewModel(
            organizationID: organization.id,
            dependencies: orgHarness.dependencies(recorder: ActionRecorder()),
            organization: { organization },
            repositoryNames: { [] }
        )
        #expect(await TestFixtures.eventually { org.rows.contains { $0.name == "API_TOKEN" } })
        let orgRow = try #require(org.rows.first { $0.name == "API_TOKEN" })
        org.copy(orgRow)
        #expect(orgHarness.pasteboardString == nil)
        await Self.confirm(org.notesReveal)
        #expect(orgHarness.pasteboardString == EditorFixtures.secretValue)
    }
}
