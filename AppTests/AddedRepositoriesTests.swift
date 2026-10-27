import Foundation
import GitHubKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// 1.0.3: the sidebar lists only the repositories added to FX Vault until the filter says All,
/// Settings › Accounts › Choose Repositories… adds them, and both choosers search.
@MainActor
@Suite("Added repositories")
struct AddedRepositoriesTests {
    // MARK: - Sidebar filter

    @Test func addedFilterKeepsVaultRepositoriesAndAccountsWithAProblem() throws {
        let input = try SidebarViewModelTests.input()
        let owners = SidebarGrouping.owners(input, query: "", filter: .added, selectedRowID: nil)
        // Example-Org has Service in the vault; user-b needs scopes; user-z has legacy in the vault.
        // user-a, Locked-Org and Other-Owner hold only listed repositories.
        #expect(owners.map(\.login) == ["Example-Org", "user-b", "user-z"])
        #expect(owners.flatMap(\.repos).allSatisfy { $0.isImported })

        let all = SidebarGrouping.owners(input, query: "", filter: .all, selectedRowID: nil)
        #expect(all.map(\.login) == SidebarGrouping.owners(input, query: "").map(\.login))
    }

    @Test func addedFilterKeepsTheSelectedRowAndSearchesOnlyAddedRepositories() throws {
        let input = try SidebarViewModelTests.input()
        let shared = SidebarRepoModel.foldKey(owner: "Other-Owner", name: "shared")
        let selected = SidebarGrouping.owners(input, query: "", filter: .added, selectedRowID: shared)
        #expect(selected.flatMap(\.repos).map(\.fullName).contains("Other-Owner/shared"), "a repository added by name stays open")

        #expect(SidebarGrouping.owners(input, query: "alpha", filter: .added, selectedRowID: nil).isEmpty)
        #expect(SidebarGrouping.owners(input, query: "alpha", filter: .all, selectedRowID: nil).flatMap(\.repos).map(\.name) == ["Alpha"])
    }

    @Test func theFilterStartsAtAddedAndIsRemembered() async throws {
        let store = InMemoryPreferencesStore()
        let preferences = PreferencesManager(store: store)
        #expect(preferences.sidebarRepoFilter == .added)
        preferences.sidebarRepoFilter = .all
        #expect(PreferencesManager(store: store).sidebarRepoFilter == .all)
        store.set("unknown", forKey: PreferencesManager.Key.sidebarRepoFilter)
        #expect(PreferencesManager(store: store).sidebarRepoFilter == .added)

        let harness = try await TestHarness(vault: .unlocked)
        let sidebar = SidebarViewModel(app: harness.app)
        #expect(sidebar.repoFilter == .added)
        sidebar.repoFilter = .all
        #expect(harness.app.container.preferences.sidebarRepoFilter == .all)
    }

    @Test func jumpPaletteListsWhatTheSidebarFilterShows() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: MainViewModelTests.ready)
        let main = harness.app.makeMainViewModel()
        let repoID = try await harness.stageRepository(name: "kept")
        #expect(await TestFixtures.eventually { main.sidebar.input.vaultRepos.contains { $0.id == repoID } })
        main.sidebar.didAddRepository(try SidebarViewModelTests.listed(TestFixtures.owner, "listed-only"), accountLogin: TestFixtures.account)
        main.sidebar.select(repositoryID: repoID)

        main.showJumpPalette()
        #expect(try #require(main.jumpPalette).results.map(\.name).contains("kept"))
        #expect(try !#require(main.jumpPalette).results.map(\.name).contains("listed-only"))
        main.showJumpPalette()

        main.sidebar.repoFilter = .all
        main.showJumpPalette()
        #expect(try #require(main.jumpPalette).results.map(\.name).contains("listed-only"))
    }

    // MARK: - Choose Vaults… search

    @Test func vaultSearchFiltersTheListNotTheSelection() async throws {
        let harness = try await ConnectAzureTests.scripted()
        let connect = harness.app.makeConnectViewModel()
        await connect.load()
        connect.goToAzure()
        await connect.azure.load()
        let azure = connect.azure
        #expect(azure.isSearchable)

        azure.query = " SHARED "
        #expect(azure.visibleSubscriptions.flatMap(\.vaults).map(\.name) == ["kv-example-shared"])
        #expect(azure.selectedVaults.count == 2, "the search never unchecks a vault")
        azure.query = "production"
        #expect(azure.visibleSubscriptions.flatMap(\.vaults).count == 2, "the subscription's name matches too")
        azure.query = "nothing"
        #expect(azure.visibleSubscriptions.isEmpty)
    }

    // MARK: - Choose Repositories…

    /// user-a lists `user-a/dotfiles` and `user-a/website`; every read an import needs answers
    /// with an empty repository.
    static func scripted(failingView: String? = nil) async throws -> TestHarness {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        try harness.installFakeGH()
        harness.stubAuthStatus(TestFixtures.authStatusTwoAccounts)
        harness.stubToken()
        harness.runner.stub(argumentsPrefix: ["org", "list"], with: .success(""))
        harness.runner.stub(
            argumentsPrefix: ["repo", "list", "user-a"],
            with: .success("[\(TestFixtures.repoJSON(owner: "user-a", name: "dotfiles", permission: "ADMIN")),\(TestFixtures.repoJSON(owner: "user-a", name: "website", permission: "ADMIN"))]")
        )
        harness.runner.stub(argumentsPrefix: ["repo", "list"], with: .success("[]"))
        harness.runner.respond(argumentsPrefix: ["repo", "view"]) { invocation in
            let name = invocation.arguments.first { $0.hasPrefix("user-a/") }?.split(separator: "/").last.map(String.init) ?? "dotfiles"
            if name == failingView { return .failure(stderr: "HTTP 404: Not Found") }
            return .success(TestFixtures.repoJSON(owner: "user-a", name: name, permission: "ADMIN"))
        }
        harness.runner.stub(argumentsPrefix: ["secret", "list"], with: .success("[]"))
        harness.runner.stub(argumentsPrefix: ["variable", "list"], with: .success("[]"))
        harness.runner.stub(argumentsPrefix: ["api"], with: .success(#"[{"total_count":0,"environments":[]}]"#))
        await harness.app.refreshGHStatus()
        return harness
    }

    @Test func chooseRepositoriesSearchesAndImportsTheCheckedOnes() async throws {
        let harness = try await Self.scripted()
        let chooser = ChooseRepositoriesModel(accountLogin: "user-a", catalog: harness.data.catalog, isUnlocked: { true })
        await chooser.load()
        #expect(chooser.failure == nil)
        let repositories = chooser.visibleOwners.flatMap(\.repositories)
        #expect(repositories.map(\.ref.name) == ["dotfiles", "website"])
        #expect(chooser.isSearchable)

        chooser.query = "web"
        #expect(chooser.visibleOwners.flatMap(\.repositories).map(\.ref.name) == ["website"])
        chooser.query = "nothing"
        #expect(chooser.visibleOwners.isEmpty)
        chooser.query = ""

        let website = try #require(repositories.last)
        chooser.toggle(website)
        #expect(chooser.selectedRepositories.map(\.ref.name) == ["website"])
        let result = await chooser.importSelected()
        #expect(result == ChooseRepositoriesModel.ImportResult(importedCount: 1, failedNames: []))
        let vault = try harness.data.config.repositories()
        #expect(vault.map(\.name) == ["website"])

        // Listed again, the imported one is checked and can't be unchecked.
        await chooser.load()
        let reloaded = try #require(chooser.visibleOwners.flatMap(\.repositories).first { $0.ref.name == "website" })
        #expect(reloaded.isImported)
        #expect(chooser.isSelected(reloaded))
        chooser.toggle(reloaded)
        #expect(chooser.selectedRepositories.isEmpty)
    }

    @Test func aFailedImportIsNamedAndTheOthersStillImport() async throws {
        let harness = try await Self.scripted(failingView: "dotfiles")
        let chooser = ChooseRepositoriesModel(accountLogin: "user-a", catalog: harness.data.catalog, isUnlocked: { true })
        await chooser.load()
        for repository in chooser.visibleOwners.flatMap(\.repositories) {
            chooser.toggle(repository)
        }
        let result = await chooser.importSelected()
        #expect(result == ChooseRepositoriesModel.ImportResult(importedCount: 1, failedNames: ["user-a/dotfiles"]))
        #expect(chooser.selectedRepositories.isEmpty)
        #expect(try harness.data.config.repositories().map(\.name) == ["website"])
        #expect(ChooseRepositoriesCopy.result(result) == "Added 1 repository to FX Vault. Could not add user-a/dotfiles.")
        #expect(ChooseRepositoriesCopy.result(.init(importedCount: 0, failedNames: ["a/b"])) == "Could not add a/b.")
    }

    /// A lock during Add Repositories stops it before the next repository: nothing reads gh or
    /// writes the vault after it.
    @Test func aLockStopsTheImportBeforeTheNextRepository() async throws {
        let harness = try await Self.scripted()
        var checks = 0
        let chooser = ChooseRepositoriesModel(accountLogin: "user-a", catalog: harness.data.catalog) {
            checks += 1
            return checks == 1
        }
        await chooser.load()
        for repository in chooser.visibleOwners.flatMap(\.repositories) {
            chooser.toggle(repository)
        }
        let result = await chooser.importSelected()
        #expect(result.importedCount == 1)
        #expect(try harness.data.config.repositories().map(\.name) == ["dotfiles"])
    }

    @Test func theEmptyNoteSaysWhyTheListIsEmpty() async throws {
        let harness = try await Self.scripted()
        let chooser = ChooseRepositoriesModel(accountLogin: "user-a", catalog: harness.data.catalog, isUnlocked: { true })
        #expect(chooser.emptyNote == nil, "nothing to say while loading")
        await chooser.load()
        #expect(chooser.emptyNote == nil)
        chooser.query = "   "
        #expect(chooser.emptyNote == nil, "spaces are no search")
        chooser.query = "nothing"
        #expect(chooser.emptyNote == ChooseRepositoriesCopy.noMatches)
    }

    @Test func aRepositoryImportedMeanwhileCountsAsAdded() async throws {
        let harness = try await Self.scripted()
        let chooser = ChooseRepositoriesModel(accountLogin: "user-a", catalog: harness.data.catalog, isUnlocked: { true })
        await chooser.load()
        let website = try #require(chooser.visibleOwners.flatMap(\.repositories).last)
        chooser.toggle(website)
        try await harness.data.catalog.importRepository(website.ref, accountLogin: "user-a")
        #expect(await chooser.importSelected() == ChooseRepositoriesModel.ImportResult(importedCount: 1, failedNames: []))
    }

    @Test func aFailedListingIsShownAndCanBeRetried() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        let chooser = ChooseRepositoriesModel(accountLogin: "user-a", catalog: harness.data.catalog, isUnlocked: { true })
        #expect(!chooser.hasLoaded)
        await chooser.load()
        #expect(chooser.failure != nil)
        #expect(chooser.hasLoaded)
        #expect(chooser.visibleOwners.isEmpty)
        #expect(!chooser.isSearchable)

        let ready = try await Self.scripted()
        let retried = ChooseRepositoriesModel(accountLogin: "user-a", catalog: ready.data.catalog, isUnlocked: { true })
        await retried.load()
        #expect(retried.failure == nil)
    }

    @Test func aLoggedOutAccountOpensNoChooserAndAnEmptyChoiceAddsNothing() async throws {
        let harness = try await Self.scripted()
        let accounts = AccountsSettingsViewModel(app: harness.app)
        accounts.chooseRepositories(SidebarViewModelTests.summary("user-c", loggedIn: false))
        #expect(accounts.repositoryChooser == nil)

        await accounts.load()
        accounts.chooseRepositories(try #require(accounts.accounts.first { $0.account.login == "user-a" }))
        await accounts.addChosenRepositories()
        #expect(accounts.repositoryChooser != nil, "Add with nothing checked keeps the sheet")
        #expect(accounts.repositoryImportResult == nil)
        accounts.closeRepositoryChooser()
        #expect(accounts.repositoryChooser == nil)
    }

    @Test func searchQueryTrimsAndIgnoresCase() {
        #expect(SearchQuery("  ").isEmpty)
        #expect(SearchQuery("").matches("anything"))
        #expect(SearchQuery(" API ").matches("my-api-service"))
        #expect(SearchQuery("api").matches("web", "API-gateway"))
        #expect(!SearchQuery("api").matches("web", "worker"))
    }

    @Test func accountsSettingsOpensTheChooserAndReportsTheImport() async throws {
        let harness = try await Self.scripted()
        let accounts = AccountsSettingsViewModel(app: harness.app)
        await accounts.load()
        let account = try #require(accounts.accounts.first { $0.account.login == "user-a" })
        accounts.chooseRepositories(account)
        let chooser = try #require(accounts.repositoryChooser)
        await chooser.load()
        chooser.toggle(try #require(chooser.visibleOwners.first?.repositories.first))
        await accounts.addChosenRepositories()
        #expect(accounts.repositoryChooser == nil)
        #expect(accounts.repositoryImportResult?.importedCount == 1)
        #expect(ChooseRepositoriesCopy.result(try #require(accounts.repositoryImportResult)) == "Added 1 repository to FX Vault.")

        accounts.chooseRepositories(account)
        accounts.vaultDidLock()
        #expect(accounts.repositoryChooser == nil)
        #expect(accounts.repositoryImportResult == nil)
    }
}
