import Foundation
import SwiftUI
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// The ⌘K jump palette (1.0 D6c2; board Main2-Search): the sidebar's places, filtered as you
/// type, ↑↓ to move, ↩ to open, esc to close.
@MainActor
@Suite("Jump palette")
struct JumpPaletteTests {
    @Test func typingFiltersThePlacesAndReturnOpensTheSelectedOne() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: MainViewModelTests.ready)
        let main = harness.app.makeMainViewModel()
        let repoID = try await harness.stageRepository(name: "stripe-webhooks")
        try harness.data.config.createEnvironment(in: repoID, name: "production")
        let production = try EditorFixtures.environment(harness, repoID, named: "production")
        let folderID = try harness.data.folders.createFolder(named: "Stripe test")
        let vaultID = try harness.data.destinations.createDestination(
            repositoryID: nil,
            target: .azureKeyVault(vaultName: "kv-example-prod", tenantID: nil),
            stage: nil
        )
        #expect(await TestFixtures.eventually {
            !main.sidebar.owners.isEmpty && !main.sidebar.folders.isEmpty && !main.sidebar.keyVaults.isEmpty
        })

        main.showJumpPalette()
        let palette = try #require(main.jumpPalette)
        #expect(palette.results.map(\.name) == [TestFixtures.owner, "stripe-webhooks", "production", "kv-example-prod", "Stripe test"])

        // A name that starts with the text first, then one that contains it, then a place whose
        // path holds it (the repository's environment).
        palette.query = "stripe"
        #expect(palette.results.map(\.name) == ["Stripe test", "stripe-webhooks", "production"])
        #expect(palette.results.map(\.detail) == [
            "Folder",
            "\(TestFixtures.owner) › repository",
            "\(TestFixtures.owner) › stripe-webhooks › environment",
        ])
        #expect(palette.selectedID == palette.results.first.map { .place($0.id) })
        palette.open()
        #expect(main.jumpPalette == nil)
        #expect(main.sidebar.selectedFolderID == folderID)

        main.showJumpPalette()
        let byVault = try #require(main.jumpPalette)
        byVault.query = "prod"
        #expect(byVault.results.map(\.name) == ["production", "kv-example-prod"])
        byVault.moveSelection(.down)
        byVault.moveSelection(.down)
        #expect(byVault.selectedID == byVault.results.last.map { .place($0.id) }, "the selection stops at the last place")
        byVault.open()
        #expect(main.sidebar.selectedKeyVaultID == vaultID)

        // Every word counts, in the name or the path.
        main.showJumpPalette()
        let byPath = try #require(main.jumpPalette)
        byPath.query = "webhooks prod"
        #expect(byPath.results.map(\.name) == ["production"])
        byPath.open()
        #expect(await TestFixtures.eventually { main.scopeList?.selectedScope?.scope == .environment(production.id) })
        #expect(main.breadcrumb == [MainCopy.gitHubSection, TestFixtures.owner, "stripe-webhooks", "production"])

        main.showJumpPalette()
        let empty = try #require(main.jumpPalette)
        empty.query = "nothing-matches"
        #expect(empty.results.isEmpty)
        empty.open()
        #expect(main.jumpPalette != nil, "↩ with nothing to open keeps the palette")
        main.closeJumpPalette()
        #expect(main.jumpPalette == nil)
    }

    /// "Secrets by name" (1.0 D6c5): once something is typed, the names after the places, with
    /// where they are; ↓ crosses into them and ↩ opens the place with the row selected.
    @Test func namesFollowThePlacesAndOpenTheirRow() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: MainViewModelTests.ready)
        let main = harness.app.makeMainViewModel()
        let repoID = try await harness.stageRepository(name: "stripe-webhooks")
        try harness.data.config.createEnvironment(in: repoID, name: "production")
        let production = try EditorFixtures.environment(harness, repoID, named: "production")
        let key = try harness.data.config.addItem(
            repositoryID: repoID,
            scope: .environment(production.id),
            kind: .secret,
            name: "STRIPE_KEY",
            value: SecretBytes(utf8: EditorFixtures.secretValue)
        ).itemID
        let folderID = try harness.data.folders.createFolder(named: "Stripe test")
        try harness.data.folders.addItem(folderID: folderID, kind: .variable, name: "STRIPE_MODE", value: SecretBytes(utf8: "test"))
        #expect(await TestFixtures.eventually { !main.sidebar.owners.isEmpty && !main.sidebar.folders.isEmpty })

        main.showJumpPalette()
        let palette = try #require(main.jumpPalette)
        #expect(palette.items.isEmpty, "names wait for the typing")
        palette.query = "stripe"
        #expect(palette.results.map(\.name) == ["Stripe test", "stripe-webhooks", "production"])
        #expect(palette.items.map(\.name) == ["STRIPE_KEY", "STRIPE_MODE"])
        #expect(palette.items.map(\.detail) == ["\(TestFixtures.owner) › stripe-webhooks › production", "Folder · Stripe test"])
        for _ in palette.results {
            palette.moveSelection(.down)
        }
        #expect(palette.selectedID == .item(key))
        palette.open()
        #expect(main.jumpPalette == nil)
        #expect(await TestFixtures.eventually { main.detail?.scope == .environment(production.id) })
        #expect(main.detail?.kind == .secret)
        #expect(main.detail?.selection == [key])

        // Nothing but a name matches: it is selected first; a variable opens on Variables.
        main.showJumpPalette()
        let byFolder = try #require(main.jumpPalette)
        byFolder.query = "mode"
        #expect(byFolder.results.isEmpty)
        let mode = try #require(byFolder.items.first)
        #expect(byFolder.selectedID == .item(mode.id))
        byFolder.open()
        #expect(main.sidebar.selectedFolderID == folderID)
        #expect(main.folderDetail?.kind == .variable)
        #expect(main.folderDetail?.selection == [mode.id])
    }

    @Test func anOrganizationAndARepositoryOpenTheirSidebarPlaces() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: MainViewModelTests.ready)
        let main = harness.app.makeMainViewModel()
        let repoID = try await harness.stageRepository()
        #expect(await TestFixtures.eventually { !main.sidebar.owners.isEmpty })
        main.sidebar.searchText = "nothing-matches"

        main.showJumpPalette()
        let palette = try #require(main.jumpPalette)
        palette.query = TestFixtures.owner
        #expect(palette.results.first?.detail == "GitHub organization")
        palette.open()
        #expect(main.sidebar.selectedOrganizationOwner?.login == TestFixtures.owner)
        #expect(main.sidebar.searchText.isEmpty, "the search is cleared so the place shows")

        main.showJumpPalette()
        let byRepository = try #require(main.jumpPalette)
        byRepository.query = TestFixtures.repoName
        byRepository.open()
        #expect(main.selectedRepo?.importedRepoID == repoID)
        #expect(main.breadcrumb == [MainCopy.gitHubSection, TestFixtures.owner, TestFixtures.repoName])
    }

    /// ⌘K again closes it; a lock closes it too.
    @Test func theShortcutTogglesAndALockCloses() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: MainViewModelTests.ready)
        let main = harness.app.makeMainViewModel()
        main.showJumpPalette()
        #expect(main.jumpPalette != nil)
        main.showJumpPalette()
        #expect(main.jumpPalette == nil)

        main.showJumpPalette()
        harness.app.lock(trigger: .manual)
        #expect(main.jumpPalette == nil)
        main.showJumpPalette()
        #expect(main.jumpPalette == nil, "nothing to jump to while locked")
    }

    /// A sheet that opens over the palette (⌘N from the menu) closes it; none opens over a sheet.
    @Test func aSheetClosesItAndKeepsItClosed() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: MainViewModelTests.ready)
        let main = harness.app.makeMainViewModel()
        main.showJumpPalette()
        main.newRepository()
        #expect(main.activeSheet != nil)
        #expect(main.jumpPalette == nil)

        main.showJumpPalette()
        #expect(main.jumpPalette == nil, "no palette over a sheet")
        main.activeSheet = nil
        main.showJumpPalette()
        #expect(main.jumpPalette != nil)
    }

    /// Edit › Find (⌘F) over the palette: the sidebar search takes the focus, so the palette goes.
    @Test func findInTheSidebarClosesIt() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: MainViewModelTests.ready)
        let main = harness.app.makeMainViewModel()
        main.isSidebarHidden = true
        main.showJumpPalette()
        #expect(main.jumpPalette != nil)
        main.findInSidebar()
        #expect(main.jumpPalette == nil)
        #expect(!main.isSidebarHidden)
    }

    /// The bold part of a name: the first word of the query found in it, whatever its case
    /// and accents.
    @Test func theHighlightIgnoresCaseAndAccents() throws {
        let name = "api-service"
        let range = try #require(JumpPlaces.highlight(in: name, query: "SERV"))
        #expect(name[range] == "serv")
        let accented = "Producción"
        let accentedRange = try #require(JumpPlaces.highlight(in: accented, query: "produccion"))
        #expect(accented[accentedRange] == "Producción")
        #expect(JumpPlaces.highlight(in: name, query: "staging webhooks") == nil)
        #expect(JumpPlaces.highlight(in: name, query: "") == nil)
    }

    @Test func aDeletedEnvironmentIsNotAPlace() {
        let repositoryID = RepoID()
        let date = Date(timeIntervalSince1970: 0)
        let repository = SidebarRepoModel(
            repoKey: "user-a/api-service",
            accountLogin: "user-a",
            ownerLogin: "user-a",
            name: "api-service",
            visibility: .private,
            isArchived: false,
            isFork: false,
            isUnavailable: false,
            importedRepoID: repositoryID,
            existsOnGitHub: true
        )
        let owner = SidebarOwnerModel(
            id: "user-a",
            login: "user-a",
            accountLogin: "user-a",
            ownerType: .user,
            isPersonal: true,
            isTruncated: false,
            repos: [repository],
            organization: nil,
            problem: nil
        )
        let places = JumpPlaces.places(JumpPlaceInputModel(owners: [owner], environments: [repositoryID: [
            EnvironmentModel(repositoryID: repositoryID, name: "production", createdAt: date, updatedAt: date),
            EnvironmentModel(repositoryID: repositoryID, name: "staging", isDeleted: true, createdAt: date, updatedAt: date),
        ]]))
        #expect(places.map(\.name) == ["api-service", "production"], "a personal account has no place; staging is deleted")
    }

    /// The home's line under "Choose a place" (board Main2-Home).
    @Test func theHomeSaysHowManyChangesWait() {
        #expect(MainCopy.homePendingChanges(0) == "No pending changes")
        #expect(MainCopy.homePendingChanges(1) == "1 pending change")
        #expect(MainCopy.homePendingChanges(3) == "3 pending changes")
    }
}
