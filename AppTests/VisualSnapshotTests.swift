import AppKit
import Foundation
import GitHubKit
import SharingKit
import SwiftUI
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Rendered PNGs of the main screens for visual review of the FractalX design (v0.3.0), in
/// light and dark. Opt-in: the suite runs only when `FXV_SNAPSHOTS_DIR` names an output folder.
/// Through xcodebuild, pass it as `TEST_RUNNER_FXV_SNAPSHOTS_DIR` (xcodebuild forwards
/// `TEST_RUNNER_`-prefixed variables to the test host without the prefix).
///
/// Every screen is drawn at 2x as `<name>-<appearance>.window.png`: the view in an offscreen
/// `NSWindow` (`cacheDisplay`), which includes the AppKit-backed controls (text fields,
/// checkboxes, pickers, `Table`, `List`, `ScrollView`, `NavigationSplitView`) and, for the main
/// window, the toolbar. SwiftUI `ImageRenderer` is not used: it draws those controls as
/// placeholders or blank, which gives a reviewer nothing to check.
///
/// Data comes from the test harness (in-memory vault, scripted gh, fake transports); nothing
/// touches the real vault, the keychain or `~/Library`. Nothing is asserted about pixels.
@MainActor
@Suite("Visual snapshots", .serialized, .enabled(if: SnapshotOutput.directory != nil, "set FXV_SNAPSHOTS_DIR to render"))
struct VisualSnapshotTests {
    // MARK: - Lock and onboarding

    @Test func lockScreen() async throws {
        let harness = try await TestHarness(vault: .locked, ghStatus: .ready(version: Limits.minimumGHVersion, path: AppContainer.previewGHPath))
        try await SnapshotOutput.write("lock", size: SnapshotOutput.windowSize) {
            LockScreen(app: harness.app)
        }
    }

    @Test func onboardingPasswordStep() async throws {
        let harness = try await TestHarness(vault: .none, ghStatus: .ready(version: Limits.minimumGHVersion, path: AppContainer.previewGHPath))
        let viewModel = harness.app.makeOnboardingViewModel()
        viewModel.start()
        #expect(viewModel.step == .createPassword)
        viewModel.password = testPassword
        viewModel.passwordConfirmation = testPassword
        try await SnapshotOutput.write("onboarding-password", size: SnapshotOutput.windowSize) {
            OnboardingScreen(viewModel: viewModel)
        }
    }

    // MARK: - Main window

    @Test func mainWindow() async throws {
        let (harness, main) = try await MainSnapshotFixture.make()
        try await SnapshotOutput.write("main", size: SnapshotOutput.windowSize, isTitled: true) {
            MainScreen(viewModel: main)
        }
        withExtendedLifetime(harness) {}
    }

    /// The sidebar on its own: inside the split view it sits in a macOS 26+ glass view that a
    /// window capture draws blank.
    @Test func mainSidebar() async throws {
        let (harness, main) = try await MainSnapshotFixture.make()
        try await SnapshotOutput.write(
            "main-sidebar",
            size: CGSize(width: Theme.Layout.sidebarIdealWidth, height: Theme.Layout.windowDefaultHeight)
        ) {
            SidebarView(main: main)
                .background(Theme.Colors.surface)
        }
        withExtendedLifetime(harness) {}
    }

    @Test func mainWindowOffline() async throws {
        let (harness, main) = try await MainSnapshotFixture.make()
        harness.container.connectivity.start()
        harness.pathSource.send(.offline)
        #expect(await TestFixtures.eventually { main.connectivityBanner != nil })
        try await SnapshotOutput.write("main-offline", size: SnapshotOutput.windowSize, isTitled: true) {
            MainScreen(viewModel: main)
        }
    }

    // MARK: - Sheets and windows

    @Test func syncSummary() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let production = "production"
        let review = SyncFixtures.review(
            [SyncFixtures.preflight(executable: [
                SyncFixtures.set(.secret, "SENTRY_DSN"),
                SyncFixtures.set(.secret, "STRIPE_SECRET_KEY", environment: production, isNew: false, reason: .modified),
                SyncFixtures.set(.secret, "JWT_SIGNING_KEY", environment: production, isNew: false, reason: .forcePushed),
                SyncFixtures.set(.variable, "FEATURE_FLAGS", environment: "staging"),
                SyncFixtures.deleteItem(.secret, "LEGACY_TOKEN"),
            ])],
            estimatedWriteCost: 5
        )
        let viewModel = SyncViewModel(
            context: SyncContext(repositoryIDs: nil),
            dependencies: harness.dependencies(recorder: ActionRecorder(), isGitHubReady: true),
            service: FakeSyncService(review: .success(review)),
            openURL: { _ in }
        )
        await viewModel.load()
        #expect(viewModel.step == .summary)
        try await SnapshotOutput.write(
            "sync-summary",
            size: CGSize(width: Theme.Layout.syncSheetWidth, height: SnapshotOutput.sheetHeight)
        ) {
            SyncScreen(viewModel: viewModel)
        }
    }

    @Test func shareExportScopeStep() async throws {
        let world = try await SharingWorld()
        try await world.sender.enableTouchID()
        let viewModel = ShareExportViewModel(
            context: ShareExportContext(selection: .repository(world.senderRepositoryID)),
            dependencies: world.senderDependencies(),
            delivery: FakeShareFileDelivery(),
            identity: SharingWorld.identity,
            stagingRoot: world.sender.sandbox.appendingPathComponent("staging", isDirectory: true)
        )
        await viewModel.start()
        #expect(viewModel.step == .chooseScope)
        try await SnapshotOutput.write(
            "share-export-scope",
            size: CGSize(width: Theme.Layout.shareSheetWidth, height: SnapshotOutput.sheetHeight)
        ) {
            ShareExportScreen(viewModel: viewModel)
        }
    }

    @Test func nearbyChatConversation() async throws {
        let fixture = try await NearbyChatViewModelTests.Fixture()
        try await fixture.chat()
        let macA = fixture.macA
        let macB = fixture.macB
        macA.draft = "Hi, sending the staging token now."
        await macA.send()
        #expect(await TestFixtures.eventually { macB.messages.count == 1 })
        macB.draft = "Thanks. Codes matched on my side."
        await macB.send()
        #expect(await TestFixtures.eventually { macA.messages.count == 2 })
        macA.draft = "Attaching it as a card."
        #expect(macA.step == .chatting)
        // `NearbyChatScreen` restarts discovery in its `.task` (the window opening), which would
        // end this conversation, so the conversation is drawn with the screen's own columns:
        // the visibility pill, the people list and the conversation.
        try await SnapshotOutput.write(
            "nearby-chat",
            size: CGSize(width: Theme.Layout.chatWindowDefaultWidth, height: Theme.Layout.chatWindowDefaultHeight)
        ) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    ChatVisibilityIndicator(isVisible: macA.isVisible, displayName: macA.displayName)
                }
                .padding(.horizontal, Theme.Spacing.xLarge)
                .padding(.vertical, Theme.Spacing.largePlus)
                HairlineDivider()
                HStack(spacing: 0) {
                    ChatPeerListView(viewModel: macA)
                        .frame(width: Theme.Layout.chatPeerListWidth)
                        .background(Theme.Colors.surface)
                    HairlineDivider(axis: .vertical)
                    ChatConversationView(viewModel: macA)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        fixture.close()
    }

    @Test func preferencesSecurityTab() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        try await harness.enableTouchID()
        let preferences = PreferencesViewModel(app: harness.app)
        try await SnapshotOutput.write(
            "preferences-security",
            size: CGSize(width: Theme.Layout.settingsWidth, height: SnapshotOutput.settingsHeight)
        ) {
            SecuritySettingsScreen(preferences: preferences, viewModel: preferences.security)
        }
    }
}

// MARK: - Main window data

/// `Example-Org/example-repo` imported through the scripted gh, with the `production`
/// environment selected and five secrets in different states: synced, modified, will push,
/// added and deleted (plus one variable).
@MainActor
enum MainSnapshotFixture {
    static let owner = TestFixtures.owner
    static let name = TestFixtures.repoName
    static var fullName: String { "\(owner)/\(name)" }
    nonisolated static let production = "production"

    static func make() async throws -> (TestHarness, MainViewModel) {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        try harness.installFakeGH()
        harness.stubAuthStatus(TestFixtures.authStatusTwoAccounts)
        harness.stubToken()
        harness.runner.stub(argumentsPrefix: ["org", "list"], with: .success("\(owner)\n"))
        harness.runner.stub(
            argumentsPrefix: ["repo", "list", owner],
            with: .success("[\(TestFixtures.repoJSON(owner: owner, name: name, permission: "ADMIN"))]")
        )
        harness.runner.stub(argumentsPrefix: ["repo", "list"], with: .success("[]"))
        await harness.app.refreshGHStatus()
        try await importRepository(harness)
        let id = try #require(try await harness.data.config.observeRepositoriesOnce().first?.id)
        try await stageChanges(harness, repositoryID: id)

        let main = harness.app.makeMainViewModel()
        await main.sidebar.reload()
        #expect(await TestFixtures.eventually {
            main.sidebar.sections.flatMap(\.owners).flatMap(\.repos).contains { $0.importedRepoID == id }
        })
        let row = try #require(main.sidebar.sections.flatMap(\.owners).flatMap(\.repos).first { $0.importedRepoID == id })
        main.sidebar.selectedRowID = row.id
        let scopes = try #require(main.scopeList)
        #expect(await TestFixtures.eventually { scopes.scopes.contains { $0.environment?.name == production } })
        scopes.selectedScopeID = try #require(scopes.scopes.first { $0.environment?.name == production }).id
        let detail = try #require(main.detail)
        detail.kind = .secret
        #expect(await TestFixtures.eventually { detail.rows.count == 5 })
        return (harness, main)
    }

    private static func importRepository(_ harness: TestHarness) async throws {
        let runner = harness.runner
        enqueueRemote(runner, databaseUpdatedAt: nil)
        let result = try await harness.data.catalog.importRepository(GHRepoRef(owner: owner, name: name), accountLogin: TestFixtures.account)
        #expect(result.unreadable.isEmpty)
        // The drift check when the repository opens re-reads GitHub: a teammate changed
        // DATABASE_URL since the import ("1 change on GitHub").
        enqueueRemote(runner, databaseUpdatedAt: "2026-10-14T09:00:00.000Z")
    }

    /// Queues one read of the repository on GitHub (view, environments, branch policies, lists).
    private static func enqueueRemote(_ runner: FakeCommandRunner, databaseUpdatedAt: String?) {
        let fullName = fullName
        runner.enqueue(
            .success(TestFixtures.repoJSON(owner: owner, name: name, permission: "ADMIN")),
            matching: { $0.starts(with: ["repo", "view", fullName]) }
        )
        runner.enqueue(
            .success("""
            [{"total_count":2,"environments":[
             {"id":101,"name":"production","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z",
              "protection_rules":[{"id":9002,"type":"branch_policy"}],
              "deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}},
             {"id":102,"name":"staging","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z",
              "protection_rules":[],"deployment_branch_policy":null}]}]
            """),
            matching: { $0.first == "api" && $0.contains("repos/\(fullName)/environments?per_page=100") }
        )
        runner.enqueue(
            .success(#"[{"total_count":2,"branch_policies":[{"id":1,"name":"main","type":"branch"},{"id":2,"name":"release/*","type":"branch"}]}]"#),
            matching: { arguments in
                arguments.first == "api"
                    && arguments.contains { $0.hasPrefix("repos/\(fullName)/environments/production/deployment-branch-policies") }
            }
        )
        runner.enqueue(.success(secrets(["SENTRY_RELEASE"])), matching: list("secret", environment: nil))
        runner.enqueue(
            .success(secrets(["DATABASE_URL", "STRIPE_SECRET_KEY", "JWT_SIGNING_KEY", "LEGACY_TOKEN"], changed: databaseUpdatedAt.map { ["DATABASE_URL": $0] } ?? [:])),
            matching: list("secret", environment: production)
        )
        runner.enqueue(.success(secrets([])), matching: list("secret", environment: "staging"))
        runner.enqueue(.success("[]"), matching: list("variable", environment: nil))
        runner.enqueue(
            .success(#"[{"createdAt":"2026-09-01T08:00:00Z","name":"REGION","updatedAt":"2026-09-02T08:00:00Z","value":"me-central-1"}]"#),
            matching: list("variable", environment: production)
        )
        runner.enqueue(.success("[]"), matching: list("variable", environment: "staging"))
    }

    /// synced, modified, will push, added, deleted.
    private static func stageChanges(_ harness: TestHarness, repositoryID: RepoID) async throws {
        let config = harness.data.config
        let scope = try #require(try config.scopes(repositoryID: repositoryID).first { $0.environment?.name == production }).scope
        let items = try await config.editorItems(repositoryID: repositoryID, scope: scope)
        func item(_ itemName: String) throws -> ConfigItemModel {
            try #require(items.first { $0.name == itemName })
        }
        try config.fillValue(try item("DATABASE_URL").id, value: SecretBytes(utf8: "FXV_SNAPSHOT_DATABASE"), pushOnNextSync: false)
        let stripe = try item("STRIPE_SECRET_KEY").id
        try config.fillValue(stripe, value: SecretBytes(utf8: "FXV_SNAPSHOT_STRIPE_OLD"), pushOnNextSync: false)
        try config.editValue(stripe, value: SecretBytes(utf8: "FXV_SNAPSHOT_STRIPE_NEW"))
        let jwt = try item("JWT_SIGNING_KEY").id
        try config.fillValue(jwt, value: SecretBytes(utf8: "FXV_SNAPSHOT_JWT"), pushOnNextSync: false)
        try config.requestPush(jwt)
        try config.addItem(repositoryID: repositoryID, scope: scope, kind: .secret, name: "SENTRY_DSN", value: SecretBytes(utf8: "FXV_SNAPSHOT_SENTRY"))
        try config.deleteItem(try item("LEGACY_TOKEN").id)
    }

    private static func secrets(_ names: [String], changed: [String: String] = [:]) -> String {
        "[" + names.map { #"{"name":"\#($0)","updatedAt":"\#(changed[$0] ?? "2026-10-01T10:42:00.123Z")"}"# }.joined(separator: ",") + "]"
    }

    private static func list(_ noun: String, environment: String?) -> FakeCommandRunner.Matcher {
        let repoFlag = "--repo=\(fullName)"
        return { arguments in
            guard arguments.starts(with: [noun, "list", repoFlag]) else { return false }
            return arguments.first { $0.hasPrefix("--env=") } == environment.map { "--env=\($0)" }
        }
    }
}

private extension ConfigRepository {
    /// The repositories in the vault now (the first value of the observation stream).
    func observeRepositoriesOnce() async throws -> [RepoModel] {
        for try await repositories in observeRepositories() {
            return repositories
        }
        return []
    }
}

// MARK: - Output

/// Where and how the snapshots are written.
@MainActor
enum SnapshotOutput {
    nonisolated static let environmentKey = "FXV_SNAPSHOTS_DIR"
    static let scale: CGFloat = 2
    static let windowSize = CGSize(width: Theme.Layout.windowDefaultWidth, height: Theme.Layout.windowDefaultHeight)
    static let sheetHeight: CGFloat = 640
    static let settingsHeight: CGFloat = 560
    /// Time for observation streams and layout passes to settle before a window capture.
    static let settleDelay: Duration = .milliseconds(400)

    nonisolated static var directory: URL? {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment[environmentKey] ?? environment["TEST_RUNNER_\(environmentKey)"], !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    enum Appearance: String, CaseIterable {
        case light
        case dark

        var colorScheme: ColorScheme {
            self == .light ? .light : .dark
        }

        var appearance: NSAppearance? {
            NSAppearance(named: self == .light ? .aqua : .darkAqua)
        }
    }

    enum Failure: Error {
        case noDirectory
        case renderFailed(String)
    }

    /// Writes `<name>-light/dark.window.png` (offscreen window) and returns their paths.
    @discardableResult
    static func write(
        _ name: String,
        size: CGSize,
        isTitled: Bool = false,
        @ViewBuilder content: () -> some View
    ) async throws -> [URL] {
        guard let directory else { throw Failure.noDirectory }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for appearance in Appearance.allCases {
            let view = content()
                .frame(width: size.width, height: size.height)
                .background(Theme.Colors.ground)
                .environment(\.colorScheme, appearance.colorScheme)

            let captured = directory.appendingPathComponent("\(name)-\(appearance.rawValue).window.png")
            try await png(fromWindow: view, size: size, appearance: appearance, isTitled: isTitled).write(to: captured)
            written.append(captured)
        }
        return written
    }

    private static func png(fromWindow view: some View, size: CGSize, appearance: Appearance, isTitled: Bool) async throws -> Data {
        let hosting = NSHostingView(rootView: view)
        let style: NSWindow.StyleMask = isTitled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance.appearance
        window.contentView = hosting
        window.setContentSize(size)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: settleDelay)
        hosting.layoutSubtreeIfNeeded()

        // A titled window is captured with its frame view, so the toolbar is included.
        let target: NSView = isTitled ? (hosting.superview ?? hosting) : hosting
        let bounds = target.bounds
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale),
            pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw Failure.renderFailed("bitmap allocation failed") }
        bitmap.size = bounds.size
        target.cacheDisplay(in: bounds, to: bitmap)
        window.close()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure.renderFailed("PNG encoding failed")
        }
        return data
    }
}
