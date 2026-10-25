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

    @Test func onboardingWelcome() async throws {
        let harness = try await TestHarness(vault: .none)
        let viewModel = harness.app.makeOnboardingViewModel()
        try await SnapshotOutput.write("onboarding-welcome", size: SnapshotOutput.windowSize) {
            OnboardingScreen(viewModel: viewModel)
        }
    }

    @Test func onboardingRecoveryKeyStep() async throws {
        let harness = try await TestHarness(vault: .none)
        let viewModel = harness.app.makeOnboardingViewModel()
        viewModel.start()
        viewModel.password = testPassword
        viewModel.passwordConfirmation = testPassword
        await viewModel.createVault()
        #expect(viewModel.step == .recoveryKey)
        viewModel.hasSavedRecoveryKey = true
        try await SnapshotOutput.write("onboarding-recovery", size: SnapshotOutput.windowSize) {
            OnboardingScreen(viewModel: viewModel)
        }
    }

    @Test func connect() async throws {
        let harness = try await ConnectViewModelTests.scripted()
        let connect = harness.app.makeConnectViewModel()
        await connect.load()
        try await SnapshotOutput.write("connect", size: SnapshotOutput.windowSize) {
            ConnectScreen(viewModel: connect)
        }
    }

    @Test func connectAzure() async throws {
        let harness = try await ConnectAzureTests.scripted()
        let connect = harness.app.makeConnectViewModel()
        await connect.load()
        connect.goToAzure()
        await connect.azure.load()
        try await SnapshotOutput.write("connect-azure", size: SnapshotOutput.windowSize) {
            ConnectScreen(viewModel: connect)
        }
        harness.runner.replaceStub(argumentsPrefix: ["account", "list"], with: .success("[]"))
        await connect.azure.load()
        #expect(connect.azure.requirement == .notSignedIn)
        try await SnapshotOutput.write("connect-azure-signin", size: SnapshotOutput.windowSize) {
            ConnectScreen(viewModel: connect)
        }
    }

    @Test func connectSummary() async throws {
        let harness = try await ConnectAzureTests.scripted()
        let connect = harness.app.makeConnectViewModel()
        await connect.load()
        connect.goToAzure()
        await connect.azure.load()
        await connect.importSelected()
        #expect(connect.summary != nil)
        try await SnapshotOutput.write("connect-summary", size: SnapshotOutput.windowSize) {
            ConnectScreen(viewModel: connect)
        }
    }

    /// The notch island over a white strip, as on a screen with a notch (boards NotchUnlock,
    /// NotchPassword).
    @Test func notchIsland() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        try await harness.enableTouchID()
        harness.app.lock(trigger: .manual)
        let model = NotchIslandModel(lock: harness.app.lockScreen)
        model.notchHeight = 32
        let size = CGSize(width: Theme.Layout.islandWidth + 2 * Theme.Spacing.xHuge, height: 180)
        try await SnapshotOutput.write("island-touchid", size: size) {
            NotchIslandView(model: model).frame(maxHeight: .infinity, alignment: .top)
        }
        model.prefersPassword = true
        try await SnapshotOutput.write("island-password", size: size) {
            NotchIslandView(model: model).frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// gh missing, after **Run** of `brew install gh` (board GitHubSetup).
    @Test func ghSetupAfterRun() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: .notInstalled, fileInspector: SetupCommandRunTests.homebrew())
        harness.runner.stub(
            argumentsPrefix: ["install", "gh"],
            with: .success("==> Fetching gh\n==> Pouring gh--2.102.0.arm64_tahoe.bottle.tar.gz\n/opt/homebrew/Cellar/gh/2.102.0: 222 files, 52.3MB\n")
        )
        let setup = harness.app.makeGHSetupViewModel()
        await setup.runs.loadAvailability()
        await setup.run(.installGH)
        try await SnapshotOutput.write("gh-setup-run", size: SnapshotOutput.windowSize) {
            GHSetupScreen(viewModel: setup)
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

    /// v0.4.0: two rows selected, so the header shows the selection actions.
    @Test func mainWindowSelection() async throws {
        let (harness, main) = try await MainSnapshotFixture.make()
        let detail = try #require(main.detail)
        detail.selection = Set(detail.rows.prefix(2).map(\.id))
        try await SnapshotOutput.write("main-selection", size: SnapshotOutput.windowSize, isTitled: true) {
            MainScreen(viewModel: main)
        }
        withExtendedLifetime(harness) {}
    }

    // MARK: - Linked copies (v0.4.1)

    /// DATABASE_URL copied to the repository level and to staging: the Linked chip with 3.
    @Test func mainWindowLinked() async throws {
        let (harness, main) = try await MainSnapshotFixture.make()
        let detail = try #require(main.detail)
        try MainSnapshotFixture.linkDatabaseURL(harness, detail)
        #expect(await TestFixtures.eventually { detail.rows.first { $0.name == "DATABASE_URL" }?.linkCount == 3 })
        try await SnapshotOutput.write("main-linked", size: SnapshotOutput.windowSize, isTitled: true) {
            MainScreen(viewModel: main)
        }
        withExtendedLifetime(harness) {}
    }

    @Test func linkedCopiesPopover() async throws {
        let (harness, main) = try await MainSnapshotFixture.make()
        let detail = try #require(main.detail)
        try MainSnapshotFixture.linkDatabaseURL(harness, detail)
        #expect(await TestFixtures.eventually { detail.rows.first { $0.name == "DATABASE_URL" }?.linkCount == 3 })
        let row = try #require(detail.rows.first { $0.name == "DATABASE_URL" })
        detail.showLinkedCopies(of: row)
        try await SnapshotOutput.write("linked-popover", size: CGSize(width: Theme.Layout.linkedPopoverWidth, height: 260)) {
            LinkedCopiesPopover(row: row, viewModel: detail)
                .background(Theme.Colors.card)
        }
        withExtendedLifetime(harness) {}
    }

    @Test func copyToAnotherRepository() async throws {
        let (harness, main) = try await MainSnapshotFixture.make()
        let detail = try #require(main.detail)
        let sourceID = detail.repositoryID
        _ = try await harness.stageRepository(name: "billing-api", environments: [RepoCreationEnvironmentDraftModel(name: "staging")])
        _ = try await harness.stageRepository(name: "web-app")
        let row = try #require(detail.rows.first { $0.name == "DATABASE_URL" })
        let viewModel = CopyToRepositoryViewModel(
            context: CopyToRepositoryContext(itemIDs: [row.id], sourceRepositoryID: sourceID, sourceScope: detail.scope),
            dependencies: harness.dependencies(recorder: ActionRecorder())
        )
        await viewModel.load()
        let target = try #require(viewModel.repositories.first { $0.name == "billing-api" })
        viewModel.select(target)
        viewModel.selectedTargetID = viewModel.targets.last?.id
        try await SnapshotOutput.write("copy-to-repository", size: CGSize(width: Theme.Layout.editorSheetWidth, height: SnapshotOutput.sheetHeight)) {
            CopyToRepositoryScreen(viewModel: viewModel)
        }
        withExtendedLifetime(harness) {}
    }

    @Test func itemEditorLinkedCopies() async throws {
        let (harness, main) = try await MainSnapshotFixture.make()
        let detail = try #require(main.detail)
        try MainSnapshotFixture.linkDatabaseURL(harness, detail)
        let row = try #require(detail.rows.first { $0.name == "DATABASE_URL" })
        let viewModel = ItemEditorViewModel(
            context: ItemEditorContext(repositoryID: detail.repositoryID, scope: detail.scope, mode: .edit(row.id)),
            dependencies: harness.dependencies(recorder: ActionRecorder())
        )
        await viewModel.load()
        viewModel.value = "FXV_SNAPSHOT_DATABASE_ROTATED"
        try await SnapshotOutput.write("item-editor-linked", size: CGSize(width: Theme.Layout.editorSheetWidth, height: SnapshotOutput.linkedEditorHeight)) {
            ItemEditorScreen(viewModel: viewModel)
        }
        withExtendedLifetime(harness) {}
    }

    // MARK: - Folders in the sidebar (v0.7.0)

    /// "Mobile App" with a copied secret, a linked copy and a variable, selected.
    @Test func mainWindowFolder() async throws {
        let (harness, main) = try await MainSnapshotFixture.make()
        let folderID = try MainSnapshotFixture.mobileFolder(harness, main)
        main.sidebar.selectedFolderID = folderID
        let folder = try #require(main.folderDetail)
        #expect(await TestFixtures.eventually { folder.items.count == 3 })
        try await SnapshotOutput.write("main-folder", size: SnapshotOutput.windowSize, isTitled: true) {
            MainScreen(viewModel: main)
        }
        folder.kind = .variable
        try await SnapshotOutput.write("main-folder-variables", size: SnapshotOutput.windowSize, isTitled: true) {
            MainScreen(viewModel: main)
        }
        withExtendedLifetime(harness) {}
    }

    /// The sidebar with FOLDERS on top and one selected.
    @Test func sidebarFolders() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let folders = harness.data.folders
        let mobile = try folders.createFolder(named: "Mobile App")
        try folders.addItem(folderID: mobile, kind: .secret, name: "FIREBASE_API_KEY", value: SecretBytes(utf8: "FXV_SNAPSHOT_FIREBASE"))
        try folders.createFolder(named: "Stripe test")
        let main = harness.app.makeMainViewModel()
        #expect(await TestFixtures.eventually { main.sidebar.folders.count == 2 })
        main.sidebar.selectedFolderID = mobile
        try await SnapshotOutput.write(
            "main-sidebar-folders",
            size: CGSize(width: Theme.Layout.sidebarIdealWidth, height: Theme.Layout.windowDefaultHeight)
        ) {
            SidebarView(main: main)
                .background(Theme.Colors.surface)
        }
        withExtendedLifetime(harness) {}
    }

    /// A received copy of a folder: Save as Folder into the folder of the same name.
    @Test func folderDestination() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        try harness.data.folders.createFolder(named: "Mobile App")
        let manifest = SharePackageModel.folder(
            named: "Mobile App",
            secrets: [ShareItemModel(name: "FIREBASE_API_KEY", value: nil, valueState: .present, githubUpdatedAt: nil, syncState: .pending)],
            variables: [ShareItemModel(name: "API_URL", value: nil, valueState: .present, githubUpdatedAt: nil, syncState: .pending)],
            createdAt: harness.container.clock.now,
            producer: ShareProducerModel(version: "0.7.0"),
            sender: ShareSenderModel(displayName: "Ben")
        )
        let model = FolderDestinationModel(manifest: manifest, dependencies: harness.dependencies(recorder: ActionRecorder(), isGitHubReady: false))
        try await SnapshotOutput.write("folder-destination", size: CGSize(width: Theme.Layout.shareSheetWidth, height: 420)) {
            FolderDestinationView(model: model)
                .padding(Theme.Spacing.xLarge)
                .background(Theme.Colors.ground)
        }
        model.folderChoice = .new
        model.newFolderName = "Mobile App"
        try await SnapshotOutput.write("folder-destination-new", size: CGSize(width: Theme.Layout.shareSheetWidth, height: 420)) {
            FolderDestinationView(model: model)
                .padding(Theme.Spacing.xLarge)
                .background(Theme.Colors.ground)
        }
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

    // MARK: - Destinations (v0.8.0)

    /// A Key Vault destination of the repository with pending items, next to a second vault.
    @Test func destinations() async throws {
        let (harness, main) = try await MainSnapshotFixture.make()
        let scopes = try #require(main.scopeList)
        let ids = try MainSnapshotFixture.destinations(harness, repositoryID: scopes.repositoryID)
        #expect(await TestFixtures.eventually { scopes.destinations.count == 2 })
        scopes.select(destination: ids.vault)
        let vault = try #require(main.destinationDetail)
        #expect(await TestFixtures.eventually { vault.items.count == 4 })
        try await SnapshotOutput.write("main-destination-keyvault", size: SnapshotOutput.windowSize, isTitled: true) {
            MainScreen(viewModel: main)
        }
        withExtendedLifetime(harness) {}
    }

    /// A Key Vault of its own (B8b3) selected under AZURE KEY VAULT.
    @Test func mainStandaloneKeyVault() async throws {
        let (harness, main) = try await MainSnapshotFixture.make()
        let destinations = harness.data.destinations
        let id = try destinations.createDestination(
            repositoryID: nil,
            target: .azureKeyVault(vaultName: "kv-example-shared", tenantID: nil),
            stage: nil
        )
        for name in ["DATABASE_URL", "STRIPE_SECRET_KEY"] {
            try destinations.addItem(destinationID: id, kind: .secret, name: name, value: SecretBytes(utf8: "FXV_SNAPSHOT_\(name)"))
        }
        #expect(await TestFixtures.eventually { main.sidebar.keyVault(id)?.itemCount == 2 })
        main.sidebar.selectedKeyVaultID = id
        let vault = try #require(main.destinationDetail)
        #expect(await TestFixtures.eventually { vault.items.count == 2 })
        try await SnapshotOutput.write("main-keyvault-standalone", size: SnapshotOutput.windowSize, isTitled: true) {
            MainScreen(viewModel: main)
        }
        withExtendedLifetime(harness) {}
    }

    @Test func addDestinationSheet() async throws {
        let (harness, main) = try await MainSnapshotFixture.make()
        let scopes = try #require(main.scopeList)
        let screen = AddDestinationScreen(
            context: AddDestinationContext(repositoryID: scopes.repositoryID),
            dependencies: harness.dependencies(recorder: ActionRecorder())
        )
        try await SnapshotOutput.write("add-destination", size: CGSize(width: Theme.Layout.destinationSheetWidth, height: 640)) {
            screen
        }
        withExtendedLifetime(harness) {}
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

    /// Two Key Vault destinations for `production`, with pending items.
    static func destinations(_ harness: TestHarness, repositoryID: RepoID) throws -> (vault: DestinationID, web: DestinationID) {
        let destinations = harness.data.destinations
        let vault = try destinations.createDestination(
            repositoryID: repositoryID,
            target: .azureKeyVault(vaultName: "kv-example-prod", tenantID: nil),
            stage: production
        )
        for name in ["DATABASE_URL", "STRIPE_SECRET_KEY", "OPENAI_API_KEY"] {
            try destinations.addItem(destinationID: vault, kind: .secret, name: name, value: SecretBytes(utf8: "FXV_SNAPSHOT_\(name)"))
        }
        try destinations.addItem(destinationID: vault, kind: .secret, name: "RESEND_API_KEY", value: SecretBytes(utf8: "FXV_SNAPSHOT_RESEND"))
        let web = try destinations.createDestination(
            repositoryID: repositoryID,
            target: .azureKeyVault(vaultName: "kv-example-web", tenantID: nil),
            stage: production
        )
        try destinations.addItem(destinationID: web, kind: .secret, name: "API_URL", value: SecretBytes(utf8: "https://api.example.invalid"))
        return (vault, web)
    }

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

    /// Copies DATABASE_URL (production) to the repository level and to staging, then changes the
    /// staging copy: three linked places, one of them with another value.
    /// "Mobile App": DATABASE_URL copied from production (a linked copy), a secret and a
    /// variable of its own.
    static func mobileFolder(_ harness: TestHarness, _ main: MainViewModel) throws -> FolderID {
        let folders = harness.data.folders
        let id = try folders.createFolder(named: "Mobile App")
        let detail = try #require(main.detail)
        let row = try #require(detail.rows.first { $0.name == "DATABASE_URL" })
        try folders.copyItems([row.id], to: id, conflicts: .keep)
        try folders.addItem(folderID: id, kind: .secret, name: "FIREBASE_API_KEY", value: SecretBytes(utf8: "FXV_SNAPSHOT_FIREBASE"))
        try folders.addItem(folderID: id, kind: .variable, name: "API_URL", value: SecretBytes(utf8: "https://api.example.invalid"))
        return id
    }

    static func linkDatabaseURL(_ harness: TestHarness, _ detail: RepoDetailViewModel) throws {
        let config = harness.data.config
        let row = try #require(detail.rows.first { $0.name == "DATABASE_URL" })
        let staging = try #require(try config.scopes(repositoryID: detail.repositoryID).first { $0.environment?.name == "staging" }).scope
        try config.copyItems([row.id], to: .repository, repositoryID: detail.repositoryID, conflicts: .keep)
        try config.copyItems([row.id], to: staging, repositoryID: detail.repositoryID, conflicts: .keep)
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
    /// Sheets that grow with their content (the attachment picker with its list).
    static let tallSheetHeight: CGFloat = 780
    /// The item editor with its linked copies under the value (v0.4.1).
    static let linkedEditorHeight: CGFloat = 1_020
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
