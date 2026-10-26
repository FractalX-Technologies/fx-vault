import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Copy All (1.0 D6c4; brief "Copy All (Touch ID)"): the header button and ⋯ open the sheet,
/// which asks `ReauthGate` first, then puts the place's notes text on the clipboard, concealed
/// and cleared after 30 s.
@MainActor
@Suite("Copy All")
struct CopyAllTests {
    static let notesText = """
    # Secrets · 1
    API_TOKEN=\(RepoDetailViewModelTests.secretValue)

    # Variables · 1
    BASE_URL=https://example.com

    """

    static func model(_ fixture: RepoDetailViewModelTests.Fixture) -> CopyAllViewModel {
        CopyAllViewModel(
            context: CopyAllContext(place: .place(.scope(repositoryID: fixture.repositoryID, scope: .repository))),
            dependencies: fixture.harness.dependencies(recorder: fixture.recorder)
        )
    }

    @Test func theHeaderAndMoreOpenCopyAllForTheScope() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let detail = fixture.viewModel
        #expect(await TestFixtures.eventually { detail.items.count == 2 })
        #expect(detail.canCopyAll)
        detail.copyAll()
        #expect(fixture.recorder.presented == [
            .copyAll(CopyAllContext(place: .place(.scope(repositoryID: fixture.repositoryID, scope: .repository)))),
        ])
        #expect(CopyAllCopy.accessibilityLabel == "Copy All, asks for Touch ID")
    }

    /// Nothing reaches the clipboard before the gate says yes; a wrong password copies nothing.
    /// Then the notes text, concealed, gone after the clipboard delay.
    @Test func asksTheGateFirstThenCopiesTheNotesTextAndClearsIt() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let harness = fixture.harness
        let model = Self.model(fixture)

        await model.start()
        #expect(model.step == .authenticate, "Touch ID is off: the password field waits")
        #expect(harness.pasteboardString == nil)

        model.reauth.password = otherTestPassword
        await model.authenticateWithPassword()
        #expect(model.step == .authenticate)
        #expect(model.reauth.error != nil)
        #expect(harness.pasteboardString == nil)

        let sleepersBefore = harness.clock.sleeperCount
        model.reauth.password = testPassword
        await model.authenticateWithPassword()
        #expect(model.step == .done(count: 2))
        #expect(model.reauth.password.isEmpty)
        #expect(harness.pasteboardString == Self.notesText)
        #expect(harness.pasteboard.types?.contains(ClipboardManager.Marker.concealed) == true)
        #expect(!String(describing: model.step).contains(RepoDetailViewModelTests.secretValue))

        await harness.clock.waitForSleepers(count: sleepersBefore + 1)
        harness.clock.advance(by: Timeouts.clipboardClear)
        await harness.container.clipboard.pendingClear?.value
        #expect(harness.pasteboardString == nil)
    }

    /// With Touch ID on, the sheet asks once when it appears and copies on success.
    @Test func touchIDCopiesWhenTheSheetAppears() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let harness = fixture.harness
        try await harness.enableTouchID()
        let loadsBefore = harness.biometrics.loadCount
        let model = Self.model(fixture)

        await model.start()
        #expect(harness.biometrics.loadCount == loadsBefore + 1)
        #expect(model.step == .done(count: 2))
        #expect(harness.pasteboardString == Self.notesText)
    }

    /// The authorization is single use and a lock drops the done step.
    @Test func aLockReturnsToTheGate() async throws {
        let fixture = try await RepoDetailViewModelTests.Fixture()
        let model = Self.model(fixture)
        model.reauth.password = testPassword
        await model.authenticateWithPassword()
        #expect(model.step == .done(count: 2))
        #expect(!model.reauth.isAuthorized, "consumed by the copy")

        model.vaultDidLock()
        #expect(model.step == .authenticate)
    }
}
