import Foundation
import GitHubKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Sidebar grouping and search (pure), and the vault-backed sidebar view model.
@MainActor
@Suite("Sidebar")
struct SidebarViewModelTests {
    // MARK: - Fixtures

    static func status(_ login: String, scopes: ScopeStatus = .ok, active: Bool = false) -> GHAccountStatusModel {
        GHAccountStatusModel(login: login, isActive: active, state: .ok, scopes: scopes, scopeList: nil, gitProtocol: "ssh")
    }

    static func summary(_ login: String, scopes: ScopeStatus = .ok, loggedIn: Bool = true) -> GHAccountSummaryModel {
        GHAccountSummaryModel(
            account: AccountModel(login: login, lastSeenAt: ManualClock.defaultStart),
            status: loggedIn ? status(login, scopes: scopes) : nil
        )
    }

    static func listed(_ owner: String, _ name: String, type: OwnerType = .organization, archived: Bool = false) throws -> CatalogRepoModel {
        CatalogRepoModel(
            ref: try GHRepoRef(owner: owner, name: name),
            ownerType: type,
            visibility: .private,
            isArchived: archived,
            isFork: false,
            hasAdmin: true,
            hasPush: true,
            isUnavailable: false,
            importedRepoID: nil,
            source: .listed
        )
    }

    static func vaultRepo(account: String, owner: String, name: String, archived: Bool = false) -> RepoModel {
        RepoModel(
            accountLogin: account,
            githubID: "R_\(name)",
            ownerLogin: owner,
            ownerType: owner == account ? .user : .organization,
            name: name,
            visibility: .public,
            isArchived: archived,
            hasAdmin: true,
            hasPush: true,
            origin: .imported,
            importedAt: ManualClock.defaultStart
        )
    }

    static func input() throws -> SidebarInputModel {
        let catalog = AccountCatalogModel(
            accountLogin: "user-a",
            owners: [
                OwnerCatalogModel(
                    login: "user-a",
                    ownerType: .user,
                    repositories: [try listed("user-a", "zeta", type: .user), try listed("user-a", "Alpha", type: .user)],
                    failure: nil,
                    isTruncated: false
                ),
                OwnerCatalogModel(
                    login: "Example-Org",
                    ownerType: .organization,
                    repositories: [try listed("Example-Org", "service")],
                    failure: nil,
                    isTruncated: true
                ),
                OwnerCatalogModel(
                    login: "Locked-Org",
                    ownerType: .organization,
                    repositories: [],
                    failure: .samlRequired(nil),
                    isTruncated: false
                ),
            ],
            organizationsFailure: nil
        )
        return SidebarInputModel(
            accounts: [summary("user-a"), summary("user-b", scopes: .missing(["repo", "read:org"]))],
            catalogs: ["user-a": catalog],
            addedByName: ["user-a": [try listed("Other-Owner", "shared", type: .user)]],
            vaultRepos: [
                // Imported: the vault row wins (archived since the listing).
                vaultRepo(account: "user-a", owner: "Example-Org", name: "Service", archived: true),
                // An account gh no longer lists.
                vaultRepo(account: "user-z", owner: "user-z", name: "legacy"),
            ]
        )
    }

    // MARK: - Grouping

    @Test func groupsAccountsOwnersAndRepositories() throws {
        let sections = SidebarGrouping.sections(try Self.input(), query: "")
        #expect(sections.map(\.login) == ["user-a", "user-b", "user-z"])

        let userA = try #require(sections.first)
        #expect(userA.owners.map(\.login) == ["user-a", "Example-Org", "Locked-Org", "Other-Owner"])
        #expect(userA.owners[0].isAccount)
        #expect(userA.owners[0].repos.map(\.name) == ["Alpha", "zeta"])
        #expect(userA.owners[1].isTruncated)
        #expect(userA.owners[2].requiresSAML)
        #expect(userA.owners[3].repos.map(\.fullName) == ["Other-Owner/shared"])

        let service = try #require(userA.owners[1].repos.first)
        #expect(service.isImported)
        #expect(service.isArchived)
        #expect(service.badges == [.archived])
        #expect(!userA.owners[0].repos[0].isImported)
        #expect(userA.owners[0].repos[0].badges == [.private])

        let userB = sections[1]
        #expect(userB.hasScopeWarning)
        #expect(userB.missingScopes == ["repo", "read:org"])
        #expect(userB.isLoggedIn)

        let userZ = sections[2]
        #expect(!userZ.isLoggedIn)
        #expect(userZ.owners.flatMap(\.repos).map(\.fullName) == ["user-z/legacy"])
    }

    @Test func rowIDsAreUniquePerAccount() throws {
        var input = try Self.input()
        // user-b lists the same repository as user-a.
        input.catalogs["user-b"] = AccountCatalogModel(
            accountLogin: "user-b",
            owners: [OwnerCatalogModel(
                login: "Example-Org",
                ownerType: .organization,
                repositories: [try Self.listed("Example-Org", "service")],
                failure: nil,
                isTruncated: false
            )],
            organizationsFailure: nil
        )
        let ids = SidebarGrouping.sections(input, query: "").flatMap(\.owners).flatMap(\.repos).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func searchKeepsMatchingRepositoriesOnly() throws {
        let sections = SidebarGrouping.sections(try Self.input(), query: "SERV")
        #expect(sections.map(\.login) == ["user-a"])
        #expect(sections[0].owners.map(\.login) == ["Example-Org"])
        #expect(sections[0].owners[0].repos.map(\.name) == ["Service"])

        #expect(SidebarGrouping.sections(try Self.input(), query: "nothing-matches").isEmpty)
        // Search matches the owner too.
        let byOwner = SidebarGrouping.sections(try Self.input(), query: "other-owner/")
        #expect(byOwner.flatMap(\.owners).flatMap(\.repos).map(\.name) == ["shared"])
    }

    // MARK: - View model over the vault

    @Test func vaultRepositoriesAppearWithoutGH() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let sidebar = SidebarViewModel(app: harness.app)
        let id = try await harness.stageRepository()
        let appeared = await TestFixtures.eventually { sidebar.input.vaultRepos.contains { $0.id == id } }
        #expect(appeared)
        let row = try #require(sidebar.sections.first?.owners.flatMap(\.repos).first)
        #expect(row.importedRepoID == id)
        #expect(row.badges == [.notOnGitHub, .private])
        #expect(!sidebar.canClone(row))
        #expect(sidebar.canRemove(row))

        sidebar.selectedRowID = row.id
        sidebar.searchText = "no-match"
        #expect(sidebar.selectedRepo?.importedRepoID == id)
    }

    @Test func selectingARepositoryWaitsForTheVaultObservation() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let sidebar = SidebarViewModel(app: harness.app)
        let id = try await harness.stageRepository()
        // Selected before the observation delivered the row (what New Repository does).
        sidebar.searchText = "no-match"
        sidebar.select(repositoryID: id)
        #expect(sidebar.searchText.isEmpty)
        let selected = await TestFixtures.eventually { sidebar.selectedRepo?.importedRepoID == id }
        #expect(selected)

        // An already listed repository is selected at once.
        sidebar.selectedRowID = nil
        sidebar.select(repositoryID: id)
        #expect(sidebar.selectedRepo?.importedRepoID == id)
    }

    @Test func removeFromVaultNeedsConfirmation() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let sidebar = SidebarViewModel(app: harness.app)
        try await harness.stageRepository()
        #expect(await TestFixtures.eventually { !sidebar.sections.isEmpty })
        let row = try #require(sidebar.sections.first?.owners.flatMap(\.repos).first)

        sidebar.requestRemoval(row)
        #expect(sidebar.pendingRemoval == row)
        await sidebar.confirmRemoval()
        #expect(sidebar.pendingRemoval == nil)
        #expect(await TestFixtures.eventually { sidebar.input.vaultRepos.isEmpty })
        #expect(sidebar.alert == nil)
    }

    @Test func catalogLoadsWhenGHIsReady() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        try harness.installFakeGH()
        harness.stubAuthStatus(TestFixtures.authStatusTwoAccounts)
        harness.stubToken()
        harness.runner.stub(argumentsPrefix: ["org", "list"], with: .success("Example-Org\n"))
        harness.runner.stub(argumentsPrefix: ["repo", "list"], with: .success("[]"))
        await harness.app.refreshGHStatus()
        let sidebar = SidebarViewModel(app: harness.app)
        await sidebar.reload()
        #expect(sidebar.accountsError == nil)
        #expect(sidebar.sections.map(\.login) == ["user-a", "user-b"])
        #expect(sidebar.sections[0].owners.map(\.login) == ["user-a", "Example-Org"])
        #expect(sidebar.sections[1].hasScopeWarning)
    }
}
