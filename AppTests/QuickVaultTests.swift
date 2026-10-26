import AppKit
import Foundation
import SwiftUI
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// The quick vault (1.0 Q1; boards QuickVault-*): the shortcut, the vault's places with recent
/// ones first, a place's lines with Copy and Reveal, Expand, and what a lock does to it.
@MainActor
@Suite("Quick vault")
struct QuickVaultTests {
    static let variableValue = "test"
    static let secretValue = "sk_test_quick_vault_value"

    /// A folder "Stripe test" with STRIPE_MODE (a variable) and STRIPE_KEY (a secret).
    static func folder(_ harness: TestHarness) throws -> FolderID {
        let folders = harness.data.folders
        let id = try folders.createFolder(named: "Stripe test")
        try folders.addItem(folderID: id, kind: .variable, name: "STRIPE_MODE", value: SecretBytes(utf8: variableValue))
        try folders.addItem(folderID: id, kind: .secret, name: "STRIPE_KEY", value: SecretBytes(utf8: secretValue))
        return id
    }

    /// The open place's lines once its observation delivered `count` of them.
    static func lines(_ quickVault: QuickVaultViewModel, count: Int) async throws -> [NotesItemLineModel] {
        let place = try #require(quickVault.place)
        #expect(await TestFixtures.eventually { place.lines.count == count })
        return place.lines
    }

    /// The menu bar's Quick Vault, once its places are read.
    static func open(_ harness: TestHarness) async {
        harness.app.openQuickVault()
        await harness.app.quickVault.loadTask?.value
    }

    static func line(_ name: String, in lines: [NotesItemLineModel]) throws -> NotesItemLineModel {
        try #require(lines.first { $0.name == name })
    }

    // MARK: - Shortcut

    @Test func theShortcutIsRegisteredAndFollowsSettings() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        #expect(harness.hotKey.registered == .standard)

        let preferences = harness.app.makePreferencesViewModel()
        let recorded = try #require(QuickVaultShortcutModel(keyCode: 9, modifierFlags: [.control, .shift], characters: "v"))
        preferences.isRecordingShortcut = true
        #expect(harness.hotKey.registered == nil, "pressing the shortcut while the box listens records it")
        preferences.quickVaultShortcut = recorded
        #expect(harness.hotKey.registered == nil)
        preferences.isRecordingShortcut = false
        #expect(harness.hotKey.registered == recorded)

        preferences.quickVaultShortcut = .standard
        #expect(harness.hotKey.registered == .standard)
    }

    @Test func theShortcutOpensAndClosesIt() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        harness.hotKey.press()
        #expect(harness.app.quickVault.isOpen)
        harness.hotKey.press()
        #expect(!harness.app.quickVault.isOpen)

        // The menu bar's Quick Vault only opens.
        harness.app.openQuickVault()
        harness.app.openQuickVault()
        #expect(harness.app.quickVault.isOpen)
    }

    // MARK: - Places

    @Test func itListsTheVaultsPlacesThenTheRecentOnes() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let repositoryID = try await harness.stageRepository(name: "api-service")
        try harness.data.config.createEnvironment(in: repositoryID, name: "production")
        let production = try EditorFixtures.environment(harness, repositoryID, named: "production")
        let folderID = try Self.folder(harness)
        _ = try harness.data.destinations.createDestination(
            repositoryID: nil,
            target: .azureKeyVault(vaultName: "kv-example-prod", tenantID: nil),
            stage: nil
        )
        let quickVault = harness.app.quickVault

        await Self.open(harness)
        // The organization isn't imported: it has no lines of its own.
        #expect(quickVault.results.map(\.row.name) == ["api-service", "production", "kv-example-prod", "Stripe test"])
        #expect(quickVault.results.map(\.row.detail) == [
            TestFixtures.owner,
            "\(TestFixtures.owner) › api-service",
            DestinationProvider.azureKeyVault.title,
            PlaceCopy.folder,
        ])
        #expect(!quickVault.showsRecents)
        // The new environment waits for Sync; the staged repository's own scope holds nothing.
        #expect(quickVault.results.map(\.hasPendingChanges) == [false, true, false, false])

        quickVault.query = "prod"
        #expect(quickVault.results.map(\.row.name) == ["production", "kv-example-prod"])
        quickVault.openSelected()
        #expect(quickVault.place?.place.holder == .place(.scope(repositoryID: repositoryID, scope: .environment(production.id))))
        quickVault.escape()
        #expect(quickVault.place == nil, "esc goes back to the search first")
        #expect(quickVault.isOpen)

        // A name finds the place it is in.
        quickVault.query = "stripe_key"
        #expect(quickVault.items.map(\.name) == ["STRIPE_KEY"])
        quickVault.openSelected()
        #expect(quickVault.place?.place.holder == .place(.folder(folderID)))
        quickVault.escape()
        quickVault.escape()
        #expect(!quickVault.isOpen)

        await Self.open(harness)
        #expect(quickVault.showsRecents)
        #expect(quickVault.results.map(\.row.name) == ["Stripe test", "production"])
        #expect(quickVault.recents.count == 2, "ids only, in memory")
    }

    // MARK: - Lines

    @Test func aVariableCopiesAtOnceAndASecretAsksFirst() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let folderID = try Self.folder(harness)
        let quickVault = harness.app.quickVault
        await Self.open(harness)
        quickVault.show(.place(.folder(folderID)))
        let lines = try await Self.lines(quickVault, count: 2)
        let place = try #require(quickVault.place)
        let mode = try Self.line("STRIPE_MODE", in: lines)
        let key = try Self.line("STRIPE_KEY", in: lines)
        #expect(key.value == .masked)

        place.copy(mode)
        #expect(harness.pasteboardString == Self.variableValue)
        #expect(place.copiedID == mode.id)
        #expect(place.reveal.request == nil)

        place.copy(key)
        #expect(place.reveal.request == NotesRevealRequestModel(id: key.id, name: "STRIPE_KEY", action: .copy))
        await place.reveal.start()
        #expect(harness.pasteboardString == Self.variableValue, "Touch ID is off: the password field waits")
        place.reveal.reauth?.password = otherTestPassword
        await place.reveal.authenticateWithPassword()
        #expect(harness.pasteboardString == Self.variableValue)
        place.reveal.reauth?.password = testPassword
        await place.reveal.authenticateWithPassword()
        #expect(harness.pasteboardString == Self.secretValue)
        #expect(place.reveal.request == nil)
        #expect(place.copiedID == key.id)
    }

    @Test func touchIDCopiesASecretAndARevealedOneCopiesAtOnce() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        try await harness.enableTouchID()
        let folderID = try Self.folder(harness)
        let quickVault = harness.app.quickVault
        await Self.open(harness)
        quickVault.show(.place(.folder(folderID)))
        let key = try Self.line("STRIPE_KEY", in: try await Self.lines(quickVault, count: 2))
        let place = try #require(quickVault.place)

        place.copy(key)
        await place.reveal.start()
        #expect(harness.biometrics.lastPrompt == FeatureDependencies.reauthPrompt(for: .copyValue))
        #expect(harness.pasteboardString == Self.secretValue)

        harness.container.clipboard.clearIfOwned()
        place.reveal.ask(key)
        await place.reveal.start()
        let revealed = try Self.line("STRIPE_KEY", in: place.lines)
        #expect(revealed.value == .revealed(Self.secretValue))
        let loads = harness.biometrics.loadCount
        place.copy(revealed)
        #expect(place.reveal.request == nil, "its value is on screen already")
        #expect(harness.biometrics.loadCount == loads)
        #expect(harness.pasteboardString == Self.secretValue)
    }

    @Test func anOrganizationsLinesCopyFromTheOrganization() async throws {
        let (harness, organization) = try await OrganizationEditingTests().imported()
        let quickVault = harness.app.quickVault
        await Self.open(harness)
        #expect(quickVault.results.map(\.row.name) == [organization.login])
        #expect(quickVault.results.map(\.row.detail) == [PlaceCopy.organization])

        quickVault.openSelected()
        let lines = try await Self.lines(quickVault, count: 3)
        let region = try Self.line("REGION", in: lines)
        let place = try #require(quickVault.place)
        #expect(!place.canCopy(try Self.line("NPM_TOKEN", in: lines)), "no value, nothing to copy")
        place.copy(region)
        #expect(harness.pasteboardString == "eu-west")
    }

    // MARK: - Expand

    @Test func expandOpensThePlaceInTheMainWindow() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: MainViewModelTests.ready)
        let main = harness.app.makeMainViewModel()
        let repositoryID = try await harness.stageRepository(name: "api-service")
        try harness.data.config.createEnvironment(in: repositoryID, name: "production")
        let production = try EditorFixtures.environment(harness, repositoryID, named: "production")
        let quickVault = harness.app.quickVault

        await Self.open(harness)
        quickVault.query = "production"
        quickVault.expand()
        #expect(!quickVault.isOpen)
        #expect(harness.app.requestedPlace == .environment(repositoryID, production.id))

        main.openRequestedPlace()
        #expect(harness.app.requestedPlace == nil)
        #expect(await TestFixtures.eventually { main.scopeList?.selectedScope?.scope == .environment(production.id) })
        #expect(quickVault.recents.first == .place(.scope(repositoryID: repositoryID, scope: .environment(production.id))))
    }

    // MARK: - Lock

    @Test func aLockClosesItAndDropsWhatItShowed() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let folderID = try Self.folder(harness)
        let quickVault = harness.app.quickVault
        await Self.open(harness)
        quickVault.show(.place(.folder(folderID)))
        let lines = try await Self.lines(quickVault, count: 2)
        let place = try #require(quickVault.place)
        place.copy(try Self.line("STRIPE_KEY", in: lines))
        place.reveal.reauth?.password = testPassword
        #expect(try Self.line("STRIPE_MODE", in: lines).value == .plain(Self.variableValue))

        harness.app.lock(trigger: .manual)
        #expect(!quickVault.isOpen)
        #expect(quickVault.place == nil)
        #expect(quickVault.results.isEmpty)
        #expect(place.reveal.request == nil)
        #expect(place.reveal.reauth == nil, "the typed password goes with it")
        #expect(try Self.line("STRIPE_MODE", in: place.lines).value == .masked, "the variable was dropped")
    }

    /// Locked, the shortcut asks for the unlock first (no name or count shows meanwhile); the
    /// quick vault opens after it, in place of the window.
    @Test func whileLockedItOpensAfterTheUnlock() async throws {
        let harness = try await TestHarness(vault: .locked)
        harness.preferences.hasAnsweredTouchIDOffer = true
        let quickVault = harness.app.quickVault

        harness.hotKey.press()
        #expect(harness.app.isQuickVaultRequested)
        #expect(!quickVault.isOpen)
        #expect(quickVault.results.isEmpty)

        harness.app.lockScreen.password = testPassword
        await harness.app.lockScreen.unlockWithPassword()
        #expect(harness.app.phase == .unlocked)
        #expect(!harness.app.isQuickVaultRequested)
        #expect(quickVault.isOpen)

        // Gone from sight, or Open FX Vault: a later unlock is the window's again.
        harness.app.lock(trigger: .manual)
        harness.hotKey.press()
        harness.app.endQuickVaultRequest()
        harness.app.lockScreen.password = testPassword
        await harness.app.lockScreen.unlockWithPassword()
        #expect(!quickVault.isOpen)

        harness.app.lock(trigger: .manual)
        harness.hotKey.press()
        harness.app.openFXVault()
        #expect(!harness.app.isQuickVaultRequested)
    }

    @Test func beforeAVaultExistsItStaysClosed() async throws {
        let harness = try await TestHarness(vault: .none)
        harness.hotKey.press()
        #expect(!harness.app.quickVault.isOpen)
        #expect(!harness.app.isQuickVaultRequested)
    }

    // MARK: - Focus

    @Test func theKeysGoBackToTheAppItOpenedOver() {
        let safari = FakeReturnApp(4242)
        let fxVault = FakeReturnApp(7)
        var focus = QuickVaultFocusReturn()
        focus.remember(frontmost: safari, own: 7)
        focus.remember(frontmost: fxVault, own: 7)
        #expect(focus.take(returnsFocus: true) === safari, "FX Vault in front later keeps the request's app")
        #expect(focus.take(returnsFocus: true) == nil, "taken once")

        focus.remember(frontmost: fxVault, own: 7)
        #expect(focus.take(returnsFocus: true) == nil, "opened from FX Vault, it stays there")
        focus.remember(frontmost: safari, own: 7)
        #expect(focus.take(returnsFocus: false) == nil, "a focus loss went elsewhere already")
        focus.remember(frontmost: safari, own: 7)
        focus.forget()
        #expect(focus.take(returnsFocus: true) == nil)
    }

    /// An app that quit while the quick vault was open gets nothing; the panel falls back to
    /// hiding FX Vault when no window of it shows.
    @Test func anAppThatQuitGetsNoKeys() {
        let safari = FakeReturnApp(4242)
        var focus = QuickVaultFocusReturn()
        focus.remember(frontmost: safari, own: 7)
        safari.isTerminated = true
        #expect(focus.take(returnsFocus: true) == nil)
    }

    /// Esc and the shortcut hand the keys back even with the main window open behind; a focus
    /// loss and a quick vault opened from FX Vault don't.
    @Test func escAndTheShortcutActivateTheAppItOpenedOver() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let quickVault = harness.app.quickVault
        let safari = FakeReturnApp(4242)
        var frontmost = safari
        quickVault.frontmostApp = { frontmost }
        var returned: [String] = []
        quickVault.onHide = { returnsFocus, app in
            returned.append("\(returnsFocus) \(app?.processIdentifier ?? 0)")
        }

        harness.app.openQuickVault()
        quickVault.escape()
        harness.hotKey.press()
        harness.hotKey.press()
        harness.app.openQuickVault()
        quickVault.didLoseFocus()
        frontmost = FakeReturnApp(ProcessInfo.processInfo.processIdentifier)
        harness.app.openQuickVault()
        quickVault.escape()
        #expect(returned == ["true 4242", "true 4242", "false 0", "true 0"])
    }

    /// Locked, the request's app gets the keys after the unlock; a request that ended leaves none.
    @Test func whileLockedTheKeysGoBackToTheRequestsApp() async throws {
        let harness = try await TestHarness(vault: .locked)
        harness.preferences.hasAnsweredTouchIDOffer = true
        let quickVault = harness.app.quickVault
        let safari = FakeReturnApp(4242)
        let fxVault = FakeReturnApp(ProcessInfo.processInfo.processIdentifier)
        var frontmost = safari
        quickVault.frontmostApp = { frontmost }
        var returned: [pid_t?] = []
        quickVault.onHide = { _, app in returned.append(app?.processIdentifier) }

        harness.hotKey.press()
        frontmost = fxVault
        harness.hotKey.press()
        harness.app.lockScreen.password = testPassword
        await harness.app.lockScreen.unlockWithPassword()
        #expect(quickVault.isOpen)
        quickVault.escape()

        harness.app.lock(trigger: .manual)
        frontmost = safari
        harness.hotKey.press()
        harness.app.endQuickVaultRequest()
        frontmost = fxVault
        harness.app.lockScreen.password = testPassword
        await harness.app.lockScreen.unlockWithPassword()
        harness.app.openQuickVault()
        quickVault.escape()
        #expect(returned == [4242, nil])
    }

    /// Touch ID's prompt may take the focus, so a focus loss waits for the check; at its end, the
    /// quick vault closes if the user went elsewhere meanwhile, and stays if they came back.
    @Test func aFocusLossDuringTheCheckClosesItOnceTheCheckEnds() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        try await harness.enableTouchID()
        let folderID = try Self.folder(harness)
        let quickVault = harness.app.quickVault
        var hasFocus = true
        quickVault.hasFocus = { hasFocus }

        for comesBack in [false, true] {
            await Self.open(harness)
            quickVault.show(.place(.folder(folderID)))
            let key = try Self.line("STRIPE_KEY", in: try await Self.lines(quickVault, count: 2))
            let place = try #require(quickVault.place)
            let prompt = CallGate()
            harness.biometrics.onNextLoad { prompt.wait() }
            place.copy(key)
            let check = Task { await place.reveal.start() }
            #expect(await TestFixtures.eventually { place.isAuthorizing })

            hasFocus = false
            quickVault.didLoseFocus()
            #expect(quickVault.isOpen, "the check keeps it open")
            hasFocus = comesBack
            let watch = try #require(quickVault.checkWatch)
            prompt.open()
            await check.value
            await watch.value
            #expect(place.copiedID == key.id)
            #expect(quickVault.isOpen == comesBack)
            quickVault.close()
            hasFocus = true
        }
    }

    /// A revealed secret masks again when its place goes: esc (back to the search), the shortcut
    /// (away) and a focus loss.
    @Test func aRevealedSecretMasksAgainWhenThePlaceGoes() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        try await harness.enableTouchID()
        let folderID = try Self.folder(harness)
        let quickVault = harness.app.quickVault

        let closes: [(String, () -> Void)] = [
            ("esc", { quickVault.escape() }),
            ("the shortcut", { harness.hotKey.press() }),
            ("a focus loss", { quickVault.didLoseFocus() }),
        ]
        for (name, close) in closes {
            if !quickVault.isOpen {
                await Self.open(harness)
            }
            quickVault.show(.place(.folder(folderID)))
            let key = try Self.line("STRIPE_KEY", in: try await Self.lines(quickVault, count: 2))
            let place = try #require(quickVault.place)
            place.reveal.ask(key)
            await place.reveal.start()
            #expect(try Self.line("STRIPE_KEY", in: place.lines).value == .revealed(Self.secretValue))
            close()
            #expect(quickVault.place == nil)
            #expect(try Self.line("STRIPE_KEY", in: place.lines).value == .masked, "after \(name)")
        }
    }

    /// Once a revealed secret masks again (after `Timeouts.revealRemask`), its Copy asks again.
    @Test func aCopyAfterTheValueMaskedAgainAsksAgain() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        try await harness.enableTouchID()
        let folderID = try Self.folder(harness)
        let quickVault = harness.app.quickVault
        await Self.open(harness)
        quickVault.show(.place(.folder(folderID)))
        let key = try Self.line("STRIPE_KEY", in: try await Self.lines(quickVault, count: 2))
        let place = try #require(quickVault.place)

        let sleepersBefore = harness.clock.sleeperCount
        place.reveal.ask(key)
        await place.reveal.start()
        let revealed = try Self.line("STRIPE_KEY", in: place.lines)
        #expect(revealed.value == .revealed(Self.secretValue))
        await harness.clock.waitForSleepers(count: sleepersBefore + 1)
        harness.clock.advance(by: Timeouts.revealRemask)
        #expect(await TestFixtures.eventually { (try? Self.line("STRIPE_KEY", in: place.lines).value) == .masked })

        place.copy(revealed)
        #expect(place.reveal.request == NotesRevealRequestModel(id: key.id, name: "STRIPE_KEY", action: .copy))
        #expect(harness.pasteboardString == nil)
    }

    @Test func aRefusedShortcutIsSaidInSettings() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let preferences = harness.app.makePreferencesViewModel()
        let taken = try #require(QuickVaultShortcutModel(keyCode: 9, modifierFlags: [.control, .shift], characters: "v"))
        harness.hotKey.takenShortcuts = [taken]
        #expect(!preferences.isQuickVaultShortcutRefused)

        preferences.quickVaultShortcut = taken
        #expect(harness.hotKey.registered == nil)
        #expect(preferences.isQuickVaultShortcutRefused)
        preferences.quickVaultShortcut = .standard
        #expect(harness.hotKey.registered == .standard)
        #expect(!preferences.isQuickVaultShortcutRefused)
    }

    // MARK: - Menu

    @Test func theMenuShowsTheShortcut() {
        #expect(QuickVaultShortcutModel.standard.keyboardShortcut == .init("v", modifiers: [.control, .option]))
        let f5 = QuickVaultShortcutModel(keyCode: 0x60, modifiers: [.control, .command], key: "F5")
        #expect(f5.keyboardShortcut?.key.character.unicodeScalars.first?.value == UInt32(NSF5FunctionKey))
        let space = QuickVaultShortcutModel(keyCode: 0x31, modifiers: [.option, .shift], key: "Space")
        #expect(space.keyboardShortcut == .init(.space, modifiers: [.option, .shift]))
    }
}

/// An app in front of FX Vault when the quick vault was asked for.
private final class FakeReturnApp: QuickVaultReturnApp {
    let processIdentifier: pid_t
    var isTerminated = false

    init(_ processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
    }

    func takeKeysFromFXVault() -> Bool {
        true
    }
}
