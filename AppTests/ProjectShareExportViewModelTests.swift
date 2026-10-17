import Foundation
import SharingKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Share Project (v0.9.0, tasks/todo.md P1–P6): stages with production unchecked and confirmed,
/// passphrases refused for production, up to 10 teammates, the expiry, delivery and clean-up.
@MainActor
@Suite("Project share export", .serialized)
struct ProjectShareExportViewModelTests {
    private func model(
        _ world: ProjectShareWorld,
        stage: String? = nil,
        delivery: FakeShareFileDelivery = FakeShareFileDelivery()
    ) async -> ProjectShareViewModel {
        let model = ProjectShareViewModel(
            context: ShareExportContext(selection: .repository(world.senderRepositoryID), stage: stage),
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

    @Test func productionStartsUncheckedAndNeedsAConfirmation() async throws {
        let world = try await ProjectShareWorld()
        let model = await model(world)

        #expect(model.stageOptions.map(\.name).sorted() == ["production", "staging"])
        let production = try #require(model.stageOptions.first { $0.isProduction })
        let staging = try #require(model.stageOptions.first { !$0.isProduction })
        #expect(model.isStageChosen(staging))
        #expect(!model.isStageChosen(production))
        #expect(model.preview?.includesProduction == false)

        model.setStage(production, chosen: true)
        #expect(model.pendingProductionStage == production)
        #expect(!model.isStageChosen(production))
        model.cancelProductionStage()
        #expect(!model.isStageChosen(production))

        model.setStage(production, chosen: true)
        model.confirmProductionStage()
        await model.settle()
        #expect(model.isStageChosen(production))
        #expect(model.preview?.includesProduction == true)
    }

    @Test func aStageFromTheOverviewStartsCheckedAlone() async throws {
        let world = try await ProjectShareWorld()
        let model = await model(world, stage: "production")
        #expect(model.chosenStageKeys == ["production"])
        #expect(model.preview?.includesProduction == true)
    }

    @Test func productionRefusesAPassphrase() async throws {
        let world = try await ProjectShareWorld()
        let model = await model(world, stage: "production")
        model.continueToSendTo()
        #expect(model.step == .sendTo)
        #expect(!model.isPassphraseAllowed)
        #expect(model.productionPlaces.isEmpty == false)
        model.setProtection(.passphrase)
        #expect(model.protection == .teammates)
        #expect(!model.canCreate)
        model.setTeammate(try #require(model.teammates.first), chosen: true)
        #expect(model.canCreate)
    }

    @Test func atMostTenTeammates() async throws {
        let world = try await ProjectShareWorld()
        for index in 0..<Limits.maxShareRecipients {
            try world.sender.data.team.addTeammate(
                TeamDeviceKeys.generate().card(login: "user-\(index)", displayName: "Teammate \(index)", macName: "Mac \(index)")
            )
        }
        let model = await model(world)
        #expect(model.teammates.count == Limits.maxShareRecipients + 1)
        for teammate in model.teammates {
            model.setTeammate(teammate, chosen: true)
        }
        #expect(model.chosenTeammateIDs.count == Limits.maxShareRecipients)
        #expect(!model.canChooseMoreTeammates)
        model.setTeammate(try #require(model.teammates.first { model.isTeammateChosen($0) }), chosen: false)
        #expect(model.canChooseMoreTeammates)
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
        model.setProtection(.passphrase)
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

    @Test func aTeammatesFileHasNoPassphrase() async throws {
        let world = try await ProjectShareWorld()
        let model = await model(world)
        model.continueToSendTo()
        model.setTeammate(try #require(model.teammates.first), chosen: true)
        await authenticateAndCreate(model)

        #expect(model.step == .done, "\(String(describing: model.alert))")
        #expect(model.passphrase == nil)
        #expect(model.sealedForNames == ["Ben"])
        #expect(model.canDeliver)
        let sent = try await world.sender.data.sharing.sentShares()
        #expect(sent.first?.mode == .teammates)
        #expect(sent.first?.recipientIDs == [world.receiverTeammateID])
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
}
