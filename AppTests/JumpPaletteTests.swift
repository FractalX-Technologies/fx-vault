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
        #expect(palette.selectedID == palette.results.first?.id)
        palette.open()
        #expect(main.jumpPalette == nil)
        #expect(main.sidebar.selectedFolderID == folderID)

        main.showJumpPalette()
        let byVault = try #require(main.jumpPalette)
        byVault.query = "prod"
        #expect(byVault.results.map(\.name) == ["production", "kv-example-prod"])
        byVault.moveSelection(.down)
        byVault.moveSelection(.down)
        #expect(byVault.selectedID == byVault.results.last?.id, "the selection stops at the last place")
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
}
