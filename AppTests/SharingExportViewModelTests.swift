import AppKit
import Foundation
import SharingKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Nearby Chat › Save as File…: ReauthGate first, what was received, the passphrase shown once
/// with the concealed copy, and Save / AirDrop of an encrypted 0600 file. Since v0.9.0 the file
/// is a schema 4 bundle in format 2 that expires.
@MainActor
@Suite("Share export", .timeLimit(.minutes(1)))
struct SharingExportViewModelTests {
    /// Mac B received Mac A's repository in Nearby Chat and chose Save as File….
    @MainActor
    struct Fixture {
        let chat: NearbyChatViewModelTests.Fixture
        let viewModel: ShareExportViewModel

        var world: SharingWorld {
            chat.world
        }

        var delivery: FakeShareFileDelivery {
            chat.fileDelivery
        }

        /// Mac B, which saves the file.
        var harness: TestHarness {
            chat.world.receiver
        }

        init(touchID: Bool = false) async throws {
            chat = try await NearbyChatViewModelTests.Fixture()
            if touchID {
                try await chat.world.receiver.enableTouchID()
            }
            try await chat.chat()
            let id = try await chat.attachRepository()
            let macB = chat.macB
            await macB.handleConfiguration(id, .saveAsFile)
            #expect(await TestFixtures.eventually { macB.fileSheet != nil })
            viewModel = try #require(macB.fileSheet)
        }

        /// Authenticates with the password and creates the file.
        func create() async {
            await viewModel.start()
            viewModel.reauth.password = testPassword
            await viewModel.authenticateWithPassword()
            await viewModel.createShareFile()
        }

        func close() {
            chat.close()
        }
    }

    @Test func touchIDRunsFirstAndUnlocksTheReview() async throws {
        let fixture = try await Fixture(touchID: true)
        defer { fixture.close() }
        let model = fixture.viewModel
        let loadsBefore = fixture.harness.biometrics.loadCount
        #expect(model.step == .authenticate)

        await model.start()

        #expect(fixture.harness.biometrics.loadCount == loadsBefore + 1)
        #expect(fixture.harness.biometrics.lastPrompt == FeatureDependencies.reauthPrompt(for: .share))
        #expect(model.step == .chooseScope)
        #expect(model.reauth.isAuthorized)
        #expect(model.preview?.itemCount == 4)
    }

    @Test func withoutTouchIDThePasswordIsRequiredAndAWrongOneIsRejected() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let model = fixture.viewModel
        await model.start()
        // The automatic Touch ID attempt fails quietly: no error, the password field remains.
        #expect(model.step == .authenticate)
        #expect(model.reauth.error == nil)
        #expect(!model.canCreate)

        model.reauth.password = otherTestPassword
        await model.authenticateWithPassword()
        #expect(model.step == .authenticate)
        #expect(model.reauth.error != nil)
        #expect(model.reauth.password.isEmpty)

        // Nothing can be created without the authorization.
        await model.createShareFile()
        #expect(model.passphrase == nil)

        model.reauth.password = testPassword
        await model.authenticateWithPassword()
        #expect(model.step == .chooseScope)
    }

    @Test func createSealsAnExpiringBundleAndShowsThePassphraseOnce() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let model = fixture.viewModel
        await fixture.create()

        #expect(model.step == .passphrase)
        let passphrase = try #require(model.passphrase)
        let generator = try #require(fixture.harness.container.passphraseGenerator)
        let words = passphrase.split(separator: "-").map(String.init)
        #expect(words.count == Limits.passphraseWordCount)
        #expect(words.allSatisfy(generator.contains))
        #expect(model.fileName == ShareExportViewModel.fileName(for: fixture.harness.clock.now))

        let staged = try #require(model.stagedFileURL)
        #expect(staged.lastPathComponent == model.fileName)
        #expect(staged.path.hasPrefix(ShareStagingFolder.defaultRoot.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: staged.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: staged.deletingLastPathComponent().path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let bytes = try Data(contentsOf: staged)
        #expect(bytes.range(of: Data(SharingWorld.secretValue.utf8)) == nil)
        #expect(bytes.range(of: Data("API_TOKEN".utf8)) == nil)

        // A format 2 file with a schema 4 bundle that expires after the default 7 days.
        let sharing = fixture.harness.data.sharing
        let inspected = try sharing.inspectFile(at: staged)
        guard case .v2Passphrase = inspected.info else {
            Issue.record("Expected a format 2 passphrase file")
            return
        }
        let opened = try await sharing.openShareFile(inspected, passphrase: passphrase, checkGitHub: false)
        guard case .bundle(let draft) = opened.document else {
            Issue.record("Expected a bundle")
            return
        }
        #expect(draft.manifest.itemCount == 4)
        #expect(draft.manifest.expiresAt == ShareExpiryChoice.default.expiry(from: draft.manifest.createdAt))
        draft.discard()

        // The authorization was single-use.
        #expect(!model.reauth.isAuthorized)
        // No value in anything the screen shows.
        #expect(!textDump(model.preview as Any, model.notice as Any).contains(SharingWorld.secretValue))
    }

    @Test func copyingThePassphraseIsConcealedAndClearedAfter30Seconds() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let model = fixture.viewModel
        await fixture.create()
        let passphrase = try #require(model.passphrase)
        let harness = fixture.harness
        // The chat's own timers sleep on the same clock: wait for the clipboard's.
        let sleepersBefore = harness.clock.sleeperCount

        model.copyPassphrase()
        #expect(harness.pasteboardString == passphrase)
        let types = harness.pasteboard.types ?? []
        #expect(types.contains(ClipboardManager.Marker.concealed))
        #expect(types.contains(ClipboardManager.Marker.transient))
        #expect(model.notice?.contains(passphrase) == false)

        await harness.clock.waitForSleepers(count: sleepersBefore + 1)
        harness.clock.advance(by: Timeouts.clipboardClear)
        await harness.container.clipboard.pendingClear?.value
        #expect(harness.pasteboardString == nil)
    }

    @Test func saveAndShareNeedTheSavedConfirmation() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let model = fixture.viewModel
        await fixture.create()
        let staged = try #require(model.stagedFileURL)
        let destination = fixture.harness.sandbox.appendingPathComponent("Saved.fxvault")
        fixture.delivery.saveDestination = destination

        #expect(!model.canDeliver)
        await model.saveToFile()
        model.shareFile()
        #expect(fixture.delivery.suggestedNames.isEmpty)
        #expect(fixture.delivery.sharedFiles.isEmpty)

        model.hasSavedPassphrase = true
        #expect(model.canDeliver)
        await model.saveToFile()
        #expect(fixture.delivery.suggestedNames == [model.fileName])
        #expect(model.savedFileURL == destination)
        #expect(try Data(contentsOf: destination) == Data(contentsOf: staged))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        model.shareFile()
        #expect(fixture.delivery.sharedFiles == [staged])
        #expect(model.isDelivering)
        // Closing while AirDrop runs keeps the staged file until the hand-off ends.
        model.close()
        #expect(model.passphrase == nil)
        #expect(FileManager.default.fileExists(atPath: staged.path))
        fixture.delivery.finishSharing(.shared)
        #expect(model.hasSent)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func aCancelledSavePanelWritesNothing() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let model = fixture.viewModel
        await fixture.create()
        model.hasSavedPassphrase = true
        fixture.delivery.saveDestination = nil
        await model.saveToFile()
        #expect(model.savedFileURL == nil)
        #expect(model.alert == nil)
        let staged = try #require(model.stagedFileURL)
        model.close()
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func aLockDropsThePassphraseAndTheAuthorization() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let model = fixture.viewModel
        await model.start()
        model.reauth.password = testPassword
        await model.authenticateWithPassword()
        #expect(model.reauth.isAuthorized)
        model.reauth.password = "typed"

        fixture.harness.app.lock(trigger: .manual)

        #expect(model.step == .authenticate)
        #expect(model.reauth.password.isEmpty)
        #expect(!model.reauth.isAuthorized)
        #expect(model.passphrase == nil)
    }

    @Test func theDefaultFileNameUsesTheLocalDate() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 14
        components.hour = 12
        let date = try #require(Calendar.current.date(from: components))
        #expect(ShareExportViewModel.fileName(for: date) == "FX Vault Share 2026-10-14.fxvault")
    }
}
