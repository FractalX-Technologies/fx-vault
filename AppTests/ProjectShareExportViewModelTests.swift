import Foundation
import SharingKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Share Project (v0.9.0, tasks/todo.md P1–P6; passphrase only since 1.0): stages, production
/// behind its own confirmation (1.0, B3b), the expiry, delivery (AirDrop included) and clean-up.
@MainActor
@Suite("Project share export", .serialized)
struct ProjectShareExportViewModelTests {
    private func model(
        _ world: ProjectShareWorld,
        delivery: FakeShareFileDelivery = FakeShareFileDelivery()
    ) async -> ProjectShareViewModel {
        let model = ProjectShareViewModel(
            context: ShareExportContext(selection: .repository(world.senderRepositoryID)),
            dependencies: world.senderDependencies(),
            delivery: delivery,
            identity: ProjectShareWorld.identity,
            stagingRoot: world.sender.sandbox
        )
        await model.start()
        await model.settle()
        return model
    }

    private func authenticateAndCreate(_ model: ProjectShareViewModel) async {
        await model.requestCreate()
        model.reauth.password = testPassword
        await model.authenticateWithPassword()
    }

    @Test func productionIsListedUncheckedAndTickingItAsksForTouchIDOnce() async throws {
        let world = try await ProjectShareWorld()
        try await world.sender.enableTouchID()
        let model = await model(world)

        #expect(model.stageOptions.map(\.name).sorted() == ["production", "staging"])
        let production = try #require(model.stageOptions.first { $0.isProduction })
        let staging = try #require(model.stageOptions.first { !$0.isProduction })
        #expect(model.isStageChosen(staging))
        #expect(!model.isStageChosen(production))
        let loadsBefore = world.sender.biometrics.loadCount

        model.setStage(production, chosen: true)
        await model.settle()
        #expect(model.isStageChosen(production))
        #expect(model.preview?.includesProduction == true)
        #expect(world.sender.biometrics.loadCount == loadsBefore + 1)
        #expect(world.sender.biometrics.lastPrompt == FeatureDependencies.reauthPrompt(for: .share))

        // Create reuses the confirmation from the tick: no second prompt.
        model.continueToSendTo()
        #expect(model.canCreate)
        await model.requestCreate()
        #expect(model.step == .done, "\(String(describing: model.alert))")
        #expect(world.sender.biometrics.loadCount == loadsBefore + 1)
        #expect(model.preview?.includesProduction == true)
        #expect(!model.productionReauth.isAuthorized)
    }

    @Test func cancellingTouchIDLeavesProductionUnchecked() async throws {
        let world = try await ProjectShareWorld()
        try await world.sender.enableTouchID()
        let model = await model(world)
        let production = try #require(model.stageOptions.first { $0.isProduction })
        world.sender.biometrics.failNextLoad(with: .cancelled)

        model.setStage(production, chosen: true)
        await model.settle()
        #expect(!model.isStageChosen(production))
        #expect(model.preview?.includesProduction == false)
        #expect(!model.productionReauth.isAuthorized)
    }

    /// Without Touch ID the box is checked and Create asks for the password as the production
    /// confirmation; the repository refuses production with the ordinary one.
    @Test func withoutTouchIDProductionIsConfirmedWithThePasswordAtCreate() async throws {
        let world = try await ProjectShareWorld()
        let model = await model(world)
        let production = try #require(model.stageOptions.first { $0.isProduction })

        model.setStage(production, chosen: true)
        await model.settle()
        #expect(model.isStageChosen(production))
        model.continueToSendTo()
        await model.requestCreate()
        #expect(model.step == .authenticate)
        #expect(model.activeReauth === model.productionReauth)

        model.activeReauth.password = testPassword
        await model.authenticateWithPassword()
        #expect(model.step == .done, "\(String(describing: model.alert))")
        #expect(model.preview?.includesProduction == true)
    }

    /// A production environment picked in the tree also needs the production confirmation.
    @Test func aProductionEnvironmentInTheTreeNeedsTheProductionConfirmation() async throws {
        let world = try await ProjectShareWorld()
        let production = try EditorFixtures.environment(world.sender, world.senderRepositoryID, named: "production")
        let model = await model(world)
        let tree = try #require(model.tree)
        let node = try #require(tree.roots.first?.children?.first { $0.id == .environment(production.id) })
        model.setChecked(true, for: node)
        await model.settle()
        #expect(model.includesProduction)
        #expect(!model.productionPlaces.isEmpty)

        model.continueToSendTo()
        #expect(model.canCreate)
        await model.requestCreate()
        #expect(model.activeReauth === model.productionReauth)
        model.activeReauth.password = testPassword
        await model.authenticateWithPassword()
        #expect(model.step == .done, "\(String(describing: model.alert))")
    }

    @Test func theExpiryMovesThePreviewDate() async throws {
        let world = try await ProjectShareWorld()
        let model = await model(world)
        let now = world.sender.clock.now
        #expect(model.preview?.expiresAt == ShareExpiryChoice.sevenDays.expiry(from: now))
        model.expiry = .oneDay
        await model.settle()
        #expect(model.preview?.expiresAt == ShareExpiryChoice.oneDay.expiry(from: now))
    }

    @Test func treeChecksAdjustTheSelection() async throws {
        let world = try await ProjectShareWorld()
        let model = await model(world)
        let tree = try #require(model.tree)
        let root = try #require(tree.roots.first)
        let destination = try #require(root.children?.first { $0.id == .destination(world.destinationID) })
        #expect(tree.state(of: destination) == .checked)
        model.setChecked(false, for: destination)
        await model.settle()
        let selection = try #require(model.selection)
        #expect(selection.repositories.first?.destinationIDs.isEmpty == true)
        #expect(model.preview?.summary.repositories.first?.destinations.isEmpty == true)

        model.setIncludesRepositoryLevel(false)
        await model.settle()
        #expect(model.selection?.repositories.first?.includesRepositoryLevel == false)
    }

    @Test func aPassphraseFileIsShownOnceAndItsStagedCopyIsRemoved() async throws {
        let world = try await ProjectShareWorld()
        let delivery = FakeShareFileDelivery()
        let model = await model(world, delivery: delivery)
        model.continueToSendTo()
        #expect(model.canCreate)
        await authenticateAndCreate(model)

        #expect(model.step == .done, "\(String(describing: model.alert))")
        let words = try #require(model.passphrase)
        #expect(words.split(separator: "-").count == Limits.passphraseWordCount)
        let staged = try #require(model.stagedFileURL)
        #expect(staged.lastPathComponent == model.fileName)
        #expect(model.fileName.hasPrefix("FX Vault share "))
        #expect(!model.canDeliver)
        model.hasSavedPassphrase = true
        #expect(model.canDeliver)
        model.shareFile()
        #expect(delivery.sharedFiles == [staged])
        delivery.finishSharing(.shared)
        #expect(model.hasSent)

        let attributes = try FileManager.default.attributesOfItem(atPath: staged.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        model.close()
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(model.passphrase == nil)
        #expect(try await world.sender.data.sharing.sentShares().count == 1)
    }

    @Test func aFolderOpensTheSheetWithOnlyThatFolder() async throws {
        let world = try await ProjectShareWorld()
        let folderID = try world.sender.data.folders.createFolder(named: "Mobile App")
        _ = try world.sender.data.folders.addItem(folderID: folderID, kind: .secret, name: "FIREBASE_KEY", value: SecretBytes(utf8: "FXV_FOLDER"))
        let model = ProjectShareViewModel(
            context: ShareExportContext(selection: .folder(folderID)),
            dependencies: world.senderDependencies(),
            delivery: FakeShareFileDelivery(),
            identity: ProjectShareWorld.identity,
            stagingRoot: world.sender.sandbox
        )
        await model.start()
        await model.settle()
        #expect(model.chosenRepositoryIDs.isEmpty)
        #expect(model.selection?.folderIDs == [folderID])
        #expect(model.preview?.summary.folders.count == 1)
        #expect(model.canContinue)
    }

    @Test func addingAndRemovingRepositories() async throws {
        let world = try await ProjectShareWorld()
        let second = try await world.sender.stageRepository(
            name: "example-web",
            items: [TestFixtures.item(.secret, "WEB_KEY", "FXV_WEB")],
            environments: [RepoCreationEnvironmentDraftModel(name: "staging", policy: .all)]
        )
        let model = await model(world)
        #expect(model.addableRepositories.map(\.id) == [second])
        await model.addRepository(second)
        await model.settle()
        #expect(model.chosenRepositoryIDs == [world.senderRepositoryID, second])
        #expect(model.stageOptions.first { $0.name == "staging" }?.repositoryIDs.count == 2)
        #expect(model.preview?.summary.repositories.count == 2)
        await model.removeRepository(world.senderRepositoryID)
        await model.settle()
        #expect(model.preview?.summary.repositories.map(\.name) == ["example-web"])
    }

    // MARK: - Authentication and delivery (ported from the 0.9 Save as File… suite)

    @Test func touchIDRunsFirstAndCreatesTheFile() async throws {
        let world = try await ProjectShareWorld()
        try await world.sender.enableTouchID()
        let model = await model(world)
        model.continueToSendTo()
        let loadsBefore = world.sender.biometrics.loadCount

        await model.requestCreate()

        #expect(world.sender.biometrics.loadCount == loadsBefore + 1)
        #expect(world.sender.biometrics.lastPrompt == FeatureDependencies.reauthPrompt(for: .share))
        #expect(model.step == .done, "\(String(describing: model.alert))")
        #expect(model.passphrase != nil)
        // The authorization was single-use.
        #expect(!model.reauth.isAuthorized)
    }

    @Test func withoutTouchIDThePasswordIsRequiredAndAWrongOneIsRejected() async throws {
        let world = try await ProjectShareWorld()
        let model = await model(world)
        model.continueToSendTo()
        await model.requestCreate()
        // The automatic Touch ID attempt fails quietly: no error, the password field remains.
        #expect(model.step == .authenticate)
        #expect(model.reauth.error == nil)
        #expect(model.passphrase == nil)

        model.reauth.password = otherTestPassword
        await model.authenticateWithPassword()
        #expect(model.step == .authenticate)
        #expect(model.reauth.error != nil)
        #expect(model.reauth.password.isEmpty)
        #expect(model.passphrase == nil)
        #expect(try await world.sender.data.sharing.sentShares().isEmpty)

        model.reauth.password = testPassword
        await model.authenticateWithPassword()
        #expect(model.step == .done)
    }

    @Test func copyingThePassphraseIsConcealedAndClearedAfter30Seconds() async throws {
        let world = try await ProjectShareWorld()
        let model = await model(world)
        model.continueToSendTo()
        await authenticateAndCreate(model)
        let passphrase = try #require(model.passphrase)
        let harness = world.sender
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
        let world = try await ProjectShareWorld()
        let delivery = FakeShareFileDelivery()
        let model = await model(world, delivery: delivery)
        model.continueToSendTo()
        await authenticateAndCreate(model)
        let staged = try #require(model.stagedFileURL)
        let destination = world.sender.sandbox.appendingPathComponent("Saved.fxvault")
        delivery.saveDestination = destination

        #expect(!model.canDeliver)
        await model.saveToFile()
        model.shareFile()
        #expect(delivery.suggestedNames.isEmpty)
        #expect(delivery.sharedFiles.isEmpty)

        model.hasSavedPassphrase = true
        await model.saveToFile()
        #expect(delivery.suggestedNames == [model.fileName])
        #expect(model.savedFileURL == destination)
        #expect(try Data(contentsOf: destination) == Data(contentsOf: staged))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        model.shareFile()
        #expect(delivery.sharedFiles == [staged])
        #expect(model.isDelivering)
        // Closing while AirDrop runs keeps the staged file until the hand-off ends.
        model.close()
        #expect(model.passphrase == nil)
        #expect(FileManager.default.fileExists(atPath: staged.path))
        delivery.finishSharing(.shared)
        #expect(model.hasSent)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func sendWithAirDropNeedsTheSavedConfirmationAndHandsOverTheFile() async throws {
        let world = try await ProjectShareWorld()
        let delivery = FakeShareFileDelivery()
        let model = await model(world, delivery: delivery)
        model.continueToSendTo()
        await authenticateAndCreate(model)
        let staged = try #require(model.stagedFileURL)
        #expect(model.canSendWithAirDrop)

        model.sendWithAirDrop()
        #expect(delivery.airDroppedFiles.isEmpty)

        model.hasSavedPassphrase = true
        model.sendWithAirDrop()
        #expect(delivery.airDroppedFiles == [staged])
        #expect(delivery.sharedFiles.isEmpty)
        #expect(model.isDelivering)
        delivery.finishSharing(.shared)
        #expect(model.hasSent)

        delivery.isAirDropAvailable = false
        #expect(!model.canSendWithAirDrop)
    }

    @Test func aCancelledSavePanelWritesNothing() async throws {
        let world = try await ProjectShareWorld()
        let delivery = FakeShareFileDelivery()
        let model = await model(world, delivery: delivery)
        model.continueToSendTo()
        await authenticateAndCreate(model)
        model.hasSavedPassphrase = true
        delivery.saveDestination = nil
        await model.saveToFile()
        #expect(model.savedFileURL == nil)
        #expect(model.alert == nil)
        let staged = try #require(model.stagedFileURL)
        model.close()
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func aLockDropsTheTypedPasswordAndTheAuthorization() async throws {
        let world = try await ProjectShareWorld()
        let model = await model(world)
        model.continueToSendTo()
        await model.requestCreate()
        model.reauth.password = "typed"

        world.sender.app.lock(trigger: .manual)

        #expect(model.step == .sendTo)
        #expect(model.reauth.password.isEmpty)
        #expect(!model.reauth.isAuthorized)
    }

    /// A lock after the file was made drops the words shown once.
    @Test func aLockAfterCreatingDropsThePassphrase() async throws {
        let world = try await ProjectShareWorld()
        let created = await model(world)
        created.continueToSendTo()
        await authenticateAndCreate(created)
        #expect(created.passphrase != nil)
        world.sender.app.lock(trigger: .manual)
        #expect(created.passphrase == nil)
        #expect(!created.hasSavedPassphrase)
    }
}
