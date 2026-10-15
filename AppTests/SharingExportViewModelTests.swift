import AppKit
import Foundation
import SharingKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Share › File…: ReauthGate first, the scope tree, the passphrase shown once with the concealed
/// copy, and Save / AirDrop of an encrypted 0600 file.
@MainActor
@Suite("Share export")
struct SharingExportViewModelTests {
    @MainActor
    struct Fixture {
        let world: SharingWorld
        let delivery = FakeShareFileDelivery()
        let viewModel: ShareExportViewModel
        let stagingRoot: URL

        init(selection: ((SharingWorld) throws -> ShareSelectionModel)? = nil, touchID: Bool = false) async throws {
            world = try await SharingWorld()
            if touchID {
                try await world.sender.enableTouchID()
            }
            stagingRoot = world.sender.sandbox.appendingPathComponent("staging", isDirectory: true)
            let chosen = try selection?(world) ?? .repository(world.senderRepositoryID)
            viewModel = ShareExportViewModel(
                context: ShareExportContext(selection: chosen),
                dependencies: world.senderDependencies(),
                delivery: delivery,
                identity: SharingWorld.identity,
                stagingRoot: stagingRoot
            )
        }

        /// Authenticates with the password and creates the file.
        func create() async {
            await viewModel.start()
            viewModel.reauth.password = testPassword
            await viewModel.authenticateWithPassword()
            await viewModel.createShareFile()
        }
    }

    @Test func touchIDRunsFirstAndUnlocksTheScopeStep() async throws {
        let fixture = try await Fixture(touchID: true)
        let model = fixture.viewModel
        let loadsBefore = fixture.world.sender.biometrics.loadCount
        #expect(model.step == .authenticate)

        await model.start()

        #expect(fixture.world.sender.biometrics.loadCount == loadsBefore + 1)
        #expect(fixture.world.sender.biometrics.lastPrompt == FeatureDependencies.reauthPrompt(for: .share))
        #expect(model.step == .chooseScope)
        #expect(model.reauth.isAuthorized)
    }

    @Test func withoutTouchIDThePasswordIsRequiredAndAWrongOneIsRejected() async throws {
        let fixture = try await Fixture()
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

    @Test func theScopeTreeSharesAnyCombinationWithPerScopeCounts() async throws {
        let fixture = try await Fixture { world in
            let scope = try world.environmentScope(in: world.sender, repositoryID: world.senderRepositoryID)
            return .environment(try #require(scope.environmentID))
        }
        let model = fixture.viewModel
        await model.start()
        let tree = try #require(model.tree)
        let repositoryLevel = try #require(tree.root.children?.first { $0.kind == .repositoryLevel })
        let environment = try #require(tree.root.children?.first { $0.kind == .environment })
        let deployKey = try #require(environment.children?.first)
        let apiToken = try #require(repositoryLevel.children?.first { $0.title == "API_TOKEN" })

        #expect(tree.root.children?.map(\.title) == ["Repository level", SharingWorld.environment])
        #expect(repositoryLevel.children?.map(\.title) == ["API_TOKEN", "NEW_SECRET", "BASE_URL"])
        #expect(tree.state(of: environment) == .checked)
        #expect(tree.state(of: deployKey) == .checked)
        #expect(tree.state(of: tree.root) == .mixed)
        #expect(model.preview?.itemCount == 1)
        #expect(model.preview?.environmentNames == [SharingWorld.environment])
        #expect(model.preview?.summary.environments.first?.includesBranchPolicy == true)

        // Unchecking leaves nothing to create.
        model.setChecked(false, for: environment)
        #expect(model.selection == nil)
        #expect(!model.canCreate)

        // One repository-level item.
        model.setChecked(true, for: apiToken)
        guard case .item = model.selection else {
            Issue.record("Expected a single item, got \(String(describing: model.selection))")
            return
        }
        #expect(await TestFixtures.eventually { model.preview?.itemCount == 1 && model.preview?.scope == .secret })

        // The whole repository level: secrets and variables, no environment.
        model.setChecked(true, for: repositoryLevel)
        #expect(await TestFixtures.eventually {
            model.preview?.summary.repositoryLevel == ShareItemCountModel(secrets: 2, variables: 1)
                && model.preview?.summary.environments.isEmpty == true
                && model.preview?.scope == .repository
        })

        // Repository level plus the environment is everything.
        model.setChecked(true, for: environment)
        #expect(model.selection == .repository(fixture.world.senderRepositoryID))
        #expect(await TestFixtures.eventually { model.preview?.itemCount == 4 })
    }

    @Test func aRepositoryItemPlusTheEnvironmentIsSealedAndImportsOnTheReceiver() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        await model.start()
        model.reauth.password = testPassword
        await model.authenticateWithPassword()
        let tree = try #require(model.tree)
        let repositoryLevel = try #require(tree.root.children?.first { $0.kind == .repositoryLevel })
        let newSecret = try #require(repositoryLevel.children?.first { $0.title == "NEW_SECRET" })
        // Everything starts checked; keep one repository-level item and the environment.
        model.setChecked(false, for: repositoryLevel)
        model.setChecked(true, for: newSecret)
        guard case .subset(let subset) = model.selection else {
            Issue.record("Expected a subset, got \(String(describing: model.selection))")
            return
        }
        #expect(subset.environmentIDs.count == 1)
        #expect(subset.itemIDs.count == 1)
        #expect(await TestFixtures.eventually { model.canCreate })
        #expect(model.preview?.summary.repositoryLevel == ShareItemCountModel(secrets: 1, variables: 0))
        #expect(model.preview?.summary.environments.map(\.includesBranchPolicy) == [true])

        await model.createShareFile()
        let file = try #require(model.stagedFileURL)
        let passphrase = try #require(model.passphrase)
        let receiver = fixture.world.receiver.data.sharing
        let draft = try await receiver.openFile(receiver.readFile(at: file), passphrase: passphrase, checkGitHub: false)
        defer { draft.discard() }
        #expect(draft.manifest.scope == .repository)
        #expect(draft.plan.repositoryItems.map(\.key.name) == ["NEW_SECRET"])
        let environment = try #require(draft.plan.environments.first)
        #expect(environment.name == SharingWorld.environment)
        #expect(environment.includesBranchPolicy)
        #expect(environment.items.map(\.key.name) == ["DEPLOY_KEY"])
        #expect(!textDump(model.preview as Any, model.tree as Any).contains(SharingWorld.secretValue))
    }

    @Test func createSealsAnEncryptedFileAndShowsThePassphraseOnce() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        await fixture.create()

        #expect(model.step == .passphrase)
        let passphrase = try #require(model.passphrase)
        let generator = try #require(fixture.world.sender.container.passphraseGenerator)
        let words = passphrase.split(separator: "-").map(String.init)
        #expect(words.count == Limits.passphraseWordCount)
        #expect(words.allSatisfy(generator.contains))
        #expect(model.fileName == ShareExportViewModel.fileName(for: fixture.world.sender.clock.now))

        let staged = try #require(model.stagedFileURL)
        #expect(staged.lastPathComponent == model.fileName)
        #expect(staged.path.hasPrefix(fixture.stagingRoot.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: staged.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: staged.deletingLastPathComponent().path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let bytes = try Data(contentsOf: staged)
        #expect(bytes.range(of: Data(SharingWorld.secretValue.utf8)) == nil)
        #expect(bytes.range(of: Data("API_TOKEN".utf8)) == nil)

        // The authorization was single-use.
        #expect(!model.reauth.isAuthorized)
        // No value in anything the screen shows.
        #expect(!textDump(model.preview as Any, model.tree as Any, model.notice as Any).contains(SharingWorld.secretValue))
    }

    @Test func copyingThePassphraseIsConcealedAndClearedAfter30Seconds() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        await fixture.create()
        let passphrase = try #require(model.passphrase)
        let harness = fixture.world.sender

        model.copyPassphrase()
        #expect(harness.pasteboardString == passphrase)
        let types = harness.pasteboard.types ?? []
        #expect(types.contains(ClipboardManager.Marker.concealed))
        #expect(types.contains(ClipboardManager.Marker.transient))
        #expect(model.notice?.contains(passphrase) == false)

        await harness.clock.waitForSleepers(count: 1)
        harness.clock.advance(by: Timeouts.clipboardClear)
        await harness.container.clipboard.pendingClear?.value
        #expect(harness.pasteboardString == nil)
    }

    @Test func saveAndShareNeedTheSavedConfirmation() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        await fixture.create()
        let staged = try #require(model.stagedFileURL)
        let destination = fixture.world.sender.sandbox.appendingPathComponent("Saved.fxvault")
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
        let model = fixture.viewModel
        await model.start()
        model.reauth.password = testPassword
        await model.authenticateWithPassword()
        #expect(model.reauth.isAuthorized)
        model.reauth.password = "typed"

        fixture.world.sender.app.lock(trigger: .manual)

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
