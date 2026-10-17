import AppKit
import Foundation
import SharingKit
import SwiftUI
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Rendered PNGs of the project share sheets (v0.9.0) in light and dark, for visual review.
/// Opt-in like ``VisualSnapshotTests``: runs only when `FXV_SNAPSHOTS_DIR` (through xcodebuild,
/// `TEST_RUNNER_FXV_SNAPSHOTS_DIR`) names an output folder. Nothing is asserted about pixels.
@MainActor
@Suite("Project share snapshots", .serialized, .enabled(if: SnapshotOutput.directory != nil, "set FXV_SNAPSHOTS_DIR to render"))
struct ProjectShareSnapshotTests {
    private static let sheetSize = CGSize(width: Theme.Layout.shareSheetWidth, height: SnapshotOutput.tallSheetHeight)
    private static let notFound = "GraphQL: Could not resolve to a Repository with the name 'Example-Org/example-api'. (repository)\n"

    private func shareModel(_ world: ProjectShareWorld, stage: String? = nil) async -> ProjectShareViewModel {
        let model = ProjectShareViewModel(
            context: ShareExportContext(selection: .repository(world.senderRepositoryID), stage: stage),
            dependencies: world.senderDependencies(),
            delivery: FakeShareFileDelivery(),
            identity: ProjectShareWorld.identity,
            stagingRoot: world.sender.sandbox
        )
        await model.start()
        await model.settle()
        return model
    }

    private func write(_ name: String, _ model: ProjectShareViewModel) async throws {
        try await SnapshotOutput.write(name, size: Self.sheetSize) {
            ProjectShareScreen(viewModel: model)
        }
    }

    @Test func contentsOneRepository() async throws {
        let world = try await ProjectShareWorld()
        try await write("project-share-contents", await shareModel(world))
    }

    @Test func contentsThreeRepositoriesAndProduction() async throws {
        let world = try await ProjectShareWorld()
        let web = try await world.sender.stageRepository(
            name: "example-web",
            items: [TestFixtures.item(.secret, "WEB_KEY", "FXV_WEB")],
            environments: [RepoCreationEnvironmentDraftModel(name: "staging", policy: .all)]
        )
        let api = try await world.sender.stageRepository(
            name: "example-api",
            items: [TestFixtures.item(.secret, "API_KEY", "FXV_API")],
            environments: [RepoCreationEnvironmentDraftModel(name: "production", policy: .all)]
        )
        let model = await shareModel(world)
        await model.addRepository(web)
        await model.addRepository(api)
        await model.settle()
        let production = try #require(model.stageOptions.first { $0.isProduction })
        model.setStage(production, chosen: true)
        model.confirmProductionStage()
        await model.settle()
        try await write("project-share-contents-three", model)
    }

    @Test func sendToWithProduction() async throws {
        let world = try await ProjectShareWorld()
        try world.sender.data.team.addTeammate(
            TeamDeviceKeys.generate().card(login: "user-c", displayName: "Cy", macName: "Cy's Mac"),
            pairedVia: .remote
        )
        let model = await shareModel(world, stage: "production")
        model.continueToSendTo()
        model.setTeammate(try #require(model.teammates.first), chosen: true)
        try await write("project-share-send-to", model)
    }

    @Test func sendToPassphrase() async throws {
        let world = try await ProjectShareWorld()
        let model = await shareModel(world)
        model.continueToSendTo()
        model.setProtection(.passphrase)
        try await write("project-share-send-to-passphrase", model)
    }

    @Test func passphraseDone() async throws {
        let world = try await ProjectShareWorld()
        let model = await shareModel(world)
        model.continueToSendTo()
        model.setProtection(.passphrase)
        await model.requestCreate()
        model.reauth.password = testPassword
        await model.authenticateWithPassword()
        #expect(model.step == .done)
        try await write("project-share-passphrase", model)
    }

    @Test func teammatesDone() async throws {
        let world = try await ProjectShareWorld()
        let model = await shareModel(world)
        model.continueToSendTo()
        model.setTeammate(try #require(model.teammates.first), chosen: true)
        await model.requestCreate()
        model.reauth.password = testPassword
        await model.authenticateWithPassword()
        #expect(model.step == .done)
        try await write("project-share-teammates-done", model)
    }

    /// ✓ in the vault, ⇣ will import from GitHub, ✕ skipped.
    @Test func openBundleWithThreeRepositories() async throws {
        let world = try await ProjectShareWorld(receiverUsesGitHub: true)
        _ = try await world.sender.stageRepository(name: "example-web", items: [TestFixtures.item(.secret, "WEB_KEY", "FXV_WEB")])
        _ = try await world.sender.stageRepository(name: "example-api", items: [TestFixtures.item(.secret, "API_KEY", "FXV_API")])
        let authorization = try await world.sender.container.reauth.authorizeShare(.fileExport, with: .password(testPassword), session: world.sender.data.session)
        let all = try await ProjectShareTreeLoader(
            config: world.sender.data.config,
            destinations: world.sender.data.destinations,
            folders: world.sender.data.folders
        ).repositories()
        let others = all.filter { $0.id != world.senderRepositoryID }.sorted { $0.name < $1.name }.map(\.id)
        let selection = try await world.sender.data.sharing.selection(
            repositoryIDs: [world.senderRepositoryID] + others,
            stages: ["staging"]
        )
        let url = world.sender.sandbox.appendingPathComponent("three.fxvault")
        let result = try await world.sender.data.sharing.exportBundle(
            selection,
            protection: .teammates([world.receiverTeammateID]),
            to: url,
            senderName: ProjectShareWorld.identity.displayName,
            appVersion: ProjectShareWorld.identity.appVersion,
            authorization: authorization
        )
        #expect(result.passphrase == nil)

        try world.receiver.installFakeGH()
        world.receiver.stubAuthStatus(TestFixtures.authStatusTwoAccounts)
        world.receiver.stubToken()
        world.receiver.runner.stub(
            argumentsPrefix: ["repo", "view", "\(TestFixtures.owner)/example-web"],
            with: .success(TestFixtures.repoJSON(owner: TestFixtures.owner, name: "example-web"))
        )
        world.receiver.runner.stub(argumentsPrefix: ["repo", "view", "\(TestFixtures.owner)/example-api"], with: .failure(stderr: Self.notFound))
        await world.receiver.app.refreshGHStatus()
        let model = ShareImportViewModel(
            context: ShareImportContext(fileURL: try world.deliver(url)),
            dependencies: world.receiverDependencies()
        )
        await model.start()
        #expect(model.step == .bundlePreview, "\(String(describing: model.failure))")
        try await SnapshotOutput.write("project-share-open", size: Self.sheetSize) {
            ShareImportScreen(viewModel: model)
        }
    }

    @Test func openExpired() async throws {
        let world = try await ProjectShareWorld()
        let exported = try await world.exportBundle(protection: .teammates([world.receiverTeammateID]), expiry: .oneDay)
        world.receiver.clock.advance(by: .seconds(2 * Timeouts.secondsPerDay))
        let model = ShareImportViewModel(
            context: ShareImportContext(fileURL: try world.deliver(exported.url)),
            dependencies: world.receiverDependencies()
        )
        await model.start()
        #expect(model.step == .failed)
        try await SnapshotOutput.write(
            "project-share-expired",
            size: CGSize(width: Theme.Layout.shareSheetWidth, height: Theme.Layout.shareSheetMinHeight)
        ) {
            ShareImportScreen(viewModel: model)
        }
    }

    @Test func settingsSharing() async throws {
        let world = try await ProjectShareWorld()
        _ = try await world.exportBundle()
        world.sender.clock.advance(by: .seconds(Timeouts.secondsPerMinute))
        _ = try await world.exportBundle(protection: .teammates([world.receiverTeammateID]))
        let model = SharingSettingsViewModel(
            sharing: world.sender.data.sharing,
            team: world.sender.data.team,
            clock: world.sender.clock,
            isUnlocked: { true }
        )
        model.show(try await world.sender.data.sharing.sentShares())
        try await SnapshotOutput.write("settings-sharing", size: CGSize(width: Theme.Layout.settingsWidth, height: SnapshotOutput.settingsHeight)) {
            SharingSettingsScreen(viewModel: model)
        }
    }
}
