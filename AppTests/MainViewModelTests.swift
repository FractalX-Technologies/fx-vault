import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// The main window: toolbar state, sync activity, selection plumbing and the sheet router.
@MainActor
@Suite("Main window")
struct MainViewModelTests {
    static let ready = GHStatusModel.ready(version: Limits.minimumGHVersion, path: "/opt/homebrew/bin/gh")

    @Test func syncButtonRules() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: Self.ready)
        let main = harness.app.makeMainViewModel()
        #expect(!main.canSync)
        main.sync()
        #expect(main.activeSheet == nil)

        harness.app.setPendingChangeCount(3)
        #expect(main.canSync)
        #expect(SyncToolbarButton.title(count: 3) == "Sync 3")
        #expect(SyncToolbarButton.title(count: 0) == "Sync")
        main.sync()
        #expect(main.activeSheet == .sync(SyncContext(repositoryIDs: nil)))
        main.activeSheet = nil

        // Disabled while a sync runs; the activity also holds the auto-lock assertion.
        let activity = harness.app.beginSyncActivity()
        #expect(main.isSyncing)
        #expect(!main.canSync)
        #expect(harness.container.autoLock.isSyncActive)
        activity.end()
        #expect(!main.isSyncing)
        #expect(!harness.container.autoLock.isSyncActive)
        #expect(main.canSync)

        // Disabled while locked; a lock ends running activities.
        let running = harness.app.beginSyncActivity()
        main.lock()
        #expect(!running.isActive)
        #expect(!main.isSyncing)
        #expect(!main.canSync)
        #expect(harness.app.phase == .locked)
    }

    @Test func syncNeedsGH() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: .notInstalled)
        let main = harness.app.makeMainViewModel()
        harness.app.setPendingChangeCount(2)
        #expect(!main.canSync)
        #expect(!main.canCreateRepository)
    }

    @Test func newRepositoryAndNothingToShareYet() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: Self.ready)
        let main = harness.app.makeMainViewModel()
        main.newRepository()
        #expect(main.activeSheet == .createRepository(CreateRepoContext(accountLogin: nil, ownerLogin: nil)))
        main.activeSheet = nil
        #expect(!main.canShareProject)
        main.shareProject()
        #expect(main.activeSheet == nil)
    }

    @Test func selectingAnImportedRepositoryBuildsTheColumns() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: Self.ready)
        let main = harness.app.makeMainViewModel()
        let id = try await harness.stageRepository(items: [TestFixtures.item(.secret, "API_TOKEN", "FXV_FIXTURE_SECRET")])
        #expect(await TestFixtures.eventually { !main.sidebar.sections.isEmpty })
        let row = try #require(main.sidebar.sections.first?.owners.flatMap(\.repos).first)
        main.sidebar.selectedRowID = row.id

        let scopes = try #require(main.scopeList)
        let detail = try #require(main.detail)
        #expect(scopes.repositoryID == id)
        #expect(detail.repositoryID == id)
        #expect(await TestFixtures.eventually { scopes.selectedScope != nil })

        // Toolbar actions follow the selection.
        #expect(main.canImportEnv)
        main.importEnv()
        #expect(main.activeSheet == .envImport(EnvImportContext(repositoryID: id, scope: .repository, fileURL: nil)))
        main.activeSheet = nil
        #expect(main.canShareProject)
        main.shareProject()
        #expect(main.activeSheet == .shareExport(ShareExportContext(selection: .repository(id))))
        main.activeSheet = nil

        // Feature actions reach the router.
        detail.add()
        #expect(main.activeSheet == .itemEditor(ItemEditorContext(repositoryID: id, scope: .repository, mode: .add(.secret))))

        // A lock dismisses the sheet.
        harness.app.lock(trigger: .manual)
        #expect(main.activeSheet == nil)
    }

    /// The sidebar tree (B11b): the repository row stands for the repository scope, its
    /// environments nest under it, and the toolbar path follows the selection.
    @Test func theRepositoryRowIsItsRepositoryScopeAndThePathFollowsTheSelection() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: Self.ready)
        let main = harness.app.makeMainViewModel()
        #expect(main.breadcrumb.isEmpty)
        let id = try await harness.stageRepository(items: [])
        try harness.data.config.createEnvironment(in: id, name: "staging")
        #expect(await TestFixtures.eventually { !main.sidebar.sections.isEmpty })
        let row = try #require(main.sidebar.sections.first?.owners.flatMap(\.repos).first)

        main.select(repository: row)
        let scopes = try #require(main.scopeList)
        #expect(await TestFixtures.eventually { scopes.environmentScopes.map(\.title) == ["staging"] })
        #expect(main.isRowSelected(row))
        #expect(main.breadcrumb == [MainCopy.gitHubSection, row.ownerLogin, row.name])

        let staging = try #require(scopes.environmentScopes.first)
        scopes.selectedScopeID = staging.id
        #expect(!main.isRowSelected(row), "the environment row is the selected one")
        #expect(main.breadcrumb == [MainCopy.gitHubSection, row.ownerLogin, row.name, "staging"])

        main.select(repository: row)
        #expect(scopes.selectedScopeID == ScopeListViewModel.repositoryScopeID)
        #expect(main.scopeList === scopes, "clicking the selected row keeps its tree")
        #expect(main.isRowSelected(row))
        #expect(main.breadcrumb.last == row.name)
    }

    /// A Key Vault of its own (B8b3) is listed under AZURE KEY VAULT and opens its destination
    /// detail; selecting anything else, or nothing, closes it.
    @Test func aKeyVaultOfItsOwnOpensFromTheSidebar() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: Self.ready)
        let main = harness.app.makeMainViewModel()
        let repoID = try await harness.stageRepository(items: [])
        let vaultID = try harness.data.destinations.createDestination(
            repositoryID: nil,
            target: .azureKeyVault(vaultName: "kv-example-prod", tenantID: nil),
            stage: nil
        )
        #expect(await TestFixtures.eventually { main.sidebar.keyVaults.map(\.id) == [vaultID] })
        #expect(await TestFixtures.eventually { !main.sidebar.sections.isEmpty })

        main.sidebar.selectedKeyVaultID = vaultID
        let detail = try #require(main.destinationDetail)
        #expect(detail.destinationID == vaultID)
        #expect(detail.repositoryID == nil)
        #expect(main.scopeList == nil)
        #expect(main.breadcrumb == [MainCopy.azureSection, "kv-example-prod"])
        #expect(main.canImportEnv)

        main.sidebar.selectedKeyVaultID = nil
        #expect(main.destinationDetail == nil, "deselecting closes the vault")
        #expect(main.breadcrumb.isEmpty)

        main.open(destinationID: vaultID)
        #expect(main.destinationDetail?.destinationID == vaultID, "a linked copy's place opens the vault")
        main.sidebar.searchText = "nothing-matches"
        #expect(main.sidebar.visibleKeyVaults.isEmpty)
        main.sidebar.searchText = ""

        let row = try #require(main.sidebar.sections.first?.owners.flatMap(\.repos).first)
        main.select(repository: row)
        #expect(main.sidebar.selectedKeyVaultID == nil)
        #expect(main.scopeList?.repositoryID == repoID)
        #expect(main.destinationDetail == nil)

        main.sidebar.selectedKeyVaultID = vaultID
        #expect(main.sidebar.selectedRowID == nil)
        try harness.data.destinations.deleteDestination(vaultID)
        #expect(await TestFixtures.eventually { main.sidebar.selectedKeyVaultID == nil })
        #expect(main.destinationDetail == nil, "a removed vault closes")

        let imported = try harness.data.destinations.createDestination(
            repositoryID: nil,
            target: .azureKeyVault(vaultName: "kv-example-new", tenantID: nil),
            stage: nil
        )
        main.open(destinationID: imported)
        #expect(await TestFixtures.eventually { main.destinationDetail?.destinationID == imported }, "a vault opened before it is listed opens once listed")
    }

    /// A repository just imported from a project file is not in the sidebar yet: the scope asked
    /// for is selected once the sidebar row and the scope column exist.
    @Test func openingAScopeBeforeItsSidebarRowExistsSelectsItWhenTheRowAppears() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: Self.ready)
        let id = try await harness.stageRepository(items: [])
        try harness.data.config.createEnvironment(in: id, name: "staging")
        let staging = try EditorFixtures.environment(harness, id, named: "staging")
        let main = harness.app.makeMainViewModel()
        try #require(main.sidebar.sections.isEmpty, "the sidebar must not list the repository yet")

        main.open(repositoryID: id, scope: .environment(staging.id))
        #expect(main.scopeList == nil)

        #expect(await TestFixtures.eventually { main.scopeList?.selectedScope?.scope == .environment(staging.id) })
        #expect(main.scopeList?.repositoryID == id)
    }

    @Test func addRepositoryByNameSelectsTheResult() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        try harness.installFakeGH()
        harness.stubAuthStatus(TestFixtures.authStatusTwoAccounts)
        harness.stubToken()
        harness.runner.stub(argumentsPrefix: ["repo", "view"], with: .success(TestFixtures.repoJSON(owner: "Other-Owner", name: "shared")))
        await harness.app.refreshGHStatus()
        let main = harness.app.makeMainViewModel()
        main.addRepositoryByName(accountLogin: TestFixtures.account)
        #expect(main.activeSheet == .addRepositoryByName(AddRepositoryContext(accountLogin: TestFixtures.account)))

        let add = AddRepositoryViewModel(
            context: AddRepositoryContext(accountLogin: TestFixtures.account),
            catalog: harness.data.catalog,
            connectivity: harness.container.connectivity,
            gitHubReachability: harness.container.gitHubReachability
        ) { repo in
            main.sidebar.didAddRepository(repo, accountLogin: TestFixtures.account)
        }
        add.fullName = "not-a-full-name"
        #expect(!add.canAdd)
        add.fullName = " Other-Owner/shared "
        #expect(add.canAdd)
        let added = await add.add()
        #expect(added, "\(String(describing: add.error))")
        #expect(main.selectedRepo?.fullName == "Other-Owner/shared")
        #expect(main.selectedRepo?.isImported == false)
    }
}

/// `.fxvault` files opened from Finder or AirDrop (§10 Scenes).
@MainActor
@Suite("Pending imports")
struct PendingImportsTests {
    static func shareFile(_ name: String) -> URL {
        URL(fileURLWithPath: "/private/tmp/fxvault-apptests/\(name).fxvault")
    }

    @Test func onlyShareFilesAreQueuedOnce() async throws {
        let harness = try await TestHarness(vault: .locked)
        var openedWindow = 0
        harness.app.setMainWindowOpener { openedWindow += 1 }

        harness.app.openShareFiles([
            Self.shareFile("first"),
            URL(fileURLWithPath: "/private/tmp/notes.txt"),
            URL(string: "https://example.com/x.fxvault") ?? Self.shareFile("first"),
            Self.shareFile("first"),
        ])
        #expect(harness.app.pendingImports == [Self.shareFile("first")])
        #expect(openedWindow == 1)

        harness.app.openShareFiles([URL(fileURLWithPath: "/private/tmp/notes.txt")])
        #expect(openedWindow == 1)

        // Nothing is handed out before unlock.
        #expect(harness.app.takeNextPendingImport() == nil)
    }

    @Test func importSheetOpensAfterUnlockOneFileAtATime() async throws {
        let harness = try await TestHarness(vault: .locked)
        harness.app.openShareFiles([Self.shareFile("first"), Self.shareFile("second")])
        try await harness.vaultManager.unlock(password: testPassword)
        harness.app.didUnlock()

        let main = harness.app.makeMainViewModel()
        main.presentNextPendingImport()
        #expect(main.activeSheet == .shareImport(ShareImportContext(fileURL: Self.shareFile("first"))))
        #expect(harness.app.pendingImports == [Self.shareFile("second")])

        // The next one waits until the sheet closes.
        main.presentNextPendingImport()
        #expect(main.activeSheet == .shareImport(ShareImportContext(fileURL: Self.shareFile("first"))))
        main.activeSheet = nil
        #expect(main.activeSheet == .shareImport(ShareImportContext(fileURL: Self.shareFile("second"))))
        #expect(harness.app.pendingImports.isEmpty)
    }

    @Test func resetVaultDropsPendingImports() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        harness.app.openShareFiles([Self.shareFile("first")])
        harness.app.didResetVault()
        #expect(harness.app.pendingImports.isEmpty)
    }
}
