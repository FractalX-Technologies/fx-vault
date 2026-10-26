import AppKit
import Foundation
import SharingKit
import SwiftUI
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Rendered PNGs of the share sheets (v0.9.0; boards Share-Pick, Share-Passphrase, Share-Open,
/// Share-OpenPreview, Share-Expired) in light and dark, for visual review.
/// Opt-in like ``VisualSnapshotTests``: runs only when `FXV_SNAPSHOTS_DIR` (through xcodebuild,
/// `TEST_RUNNER_FXV_SNAPSHOTS_DIR`) names an output folder. Nothing is asserted about pixels.
@MainActor
@Suite("Project share snapshots", .serialized, .enabled(if: SnapshotOutput.directory != nil, "set FXV_SNAPSHOTS_DIR to render"))
struct ProjectShareSnapshotTests {
    private static let pickSize = CGSize(width: Theme.Layout.sharePickWidth, height: SnapshotOutput.sheetHeight)
    private static let passphraseSize = CGSize(width: Theme.Layout.sharePassphraseWidth, height: 380)
    private static let authenticateSize = CGSize(width: Theme.Layout.sharePickWidth, height: 360)
    private static let openSize = CGSize(width: Theme.Layout.shareOpenWidth, height: 220)
    private static let openPreviewSize = CGSize(width: Theme.Layout.shareOpenPreviewWidth, height: SnapshotOutput.tallSheetHeight)
    private static let expiredSize = CGSize(width: Theme.Layout.shareExpiredWidth, height: 240)
    private static let notFound = "GraphQL: Could not resolve to a Repository with the name 'Example-Org/example-api'. (repository)\n"

    private func shareModel(_ world: ProjectShareWorld) async -> ProjectShareViewModel {
        let model = ProjectShareViewModel(
            context: ShareExportContext(selection: .repository(world.senderRepositoryID)),
            dependencies: world.senderDependencies(),
            delivery: FakeShareFileDelivery(),
            identity: ProjectShareWorld.identity,
            stagingRoot: world.sender.sandbox
        )
        await model.start()
        await model.settle()
        return model
    }

    private func write(_ name: String, _ model: ProjectShareViewModel, size: CGSize = Self.pickSize) async throws {
        try await SnapshotOutput.write(name, size: size) {
            ProjectShareScreen(viewModel: model)
        }
    }

    @Test func contentsOneRepository() async throws {
        let world = try await ProjectShareWorld()
        try await write("project-share-contents", await shareModel(world))
    }

    /// Three repositories closed in the tree; the production stage is listed unchecked, tagged.
    @Test func contentsThreeRepositoriesWithProductionBlocked() async throws {
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
        #expect(model.stageOptions.contains { $0.isProduction })
        try await write("project-share-contents-three", model)
    }

    /// Production ticked (no Touch ID here, so the password confirms it at Create): its tag, the
    /// tree's production row and the note naming the place.
    @Test func contentsWithProduction() async throws {
        let world = try await ProjectShareWorld()
        let model = await shareModel(world)
        let production = try #require(model.stageOptions.first { $0.isProduction })
        model.setStage(production, chosen: true)
        await model.settle()
        #expect(model.includesProduction)
        try await write("project-share-contents-production", model)
    }

    /// No Touch ID here: Create stops at the password.
    @Test func authenticate() async throws {
        let world = try await ProjectShareWorld()
        let model = await shareModel(world)
        await model.requestCreate()
        #expect(model.step == .authenticate)
        try await write("project-share-authenticate", model, size: Self.authenticateSize)
    }

    @Test func passphraseDone() async throws {
        let world = try await ProjectShareWorld()
        let model = await shareModel(world)
        await model.requestCreate()
        model.reauth.password = testPassword
        await model.authenticateWithPassword()
        #expect(model.step == .done)
        try await write("project-share-passphrase", model, size: Self.passphraseSize)
    }

    @Test func openPassphrase() async throws {
        let world = try await ProjectShareWorld()
        let exported = try await world.exportBundle()
        let model = ShareImportViewModel(
            context: ShareImportContext(fileURL: try world.deliver(exported.url)),
            dependencies: world.receiverDependencies()
        )
        await model.start()
        #expect(model.step == .passphrase)
        try await SnapshotOutput.write("project-share-open-passphrase", size: Self.openSize) {
            ShareImportScreen(viewModel: model)
        }
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
            to: url,
            senderName: ProjectShareWorld.identity.displayName,
            appVersion: ProjectShareWorld.identity.appVersion,
            authorization: authorization
        )
        let passphrase = try #require(result.passphrase.utf8String())
        result.passphrase.wipe()

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
        model.passphrase = passphrase
        await model.open()
        #expect(model.step == .bundlePreview, "\(String(describing: model.failure))")
        try await SnapshotOutput.write("project-share-open", size: Self.openPreviewSize) {
            ShareImportScreen(viewModel: model)
        }
    }

    @Test func openExpired() async throws {
        let world = try await ProjectShareWorld()
        let exported = try await world.exportBundle(expiry: .oneDay)
        world.receiver.clock.advance(by: .seconds(2 * Timeouts.secondsPerDay))
        let model = ShareImportViewModel(
            context: ShareImportContext(fileURL: try world.deliver(exported.url)),
            dependencies: world.receiverDependencies()
        )
        await model.start()
        model.passphrase = exported.passphrase
        await model.open()
        #expect(model.step == .failed)
        try await SnapshotOutput.write("project-share-expired", size: Self.expiredSize) {
            ShareImportScreen(viewModel: model)
        }
    }

    @Test func settingsSharing() async throws {
        let world = try await ProjectShareWorld()
        _ = try await world.exportBundle()
        world.sender.clock.advance(by: .seconds(Timeouts.secondsPerMinute))
        _ = try await world.exportBundle()
        let model = SharingSettingsViewModel(
            sharing: world.sender.data.sharing,
            clock: world.sender.clock,
            isUnlocked: { true }
        )
        model.show(try await world.sender.data.sharing.sentShares())
        try await SnapshotOutput.write("settings-sharing", size: CGSize(width: Theme.Layout.settingsWidth, height: SnapshotOutput.settingsHeight)) {
            SharingSettingsScreen(viewModel: model)
        }
    }
}
