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
