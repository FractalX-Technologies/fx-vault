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

    static func owner(_ login: String, in owners: [SidebarOwnerModel]) throws -> SidebarOwnerModel {
        try #require(owners.first { $0.login == login })
    }

    @Test func groupsOwnersAcrossAccounts() throws {
        let owners = SidebarGrouping.owners(try Self.input(), query: "")
        #expect(owners.map(\.login) == ["Example-Org", "Locked-Org", "Other-Owner", "user-a", "user-b", "user-z"])

        let userA = try Self.owner("user-a", in: owners)
        #expect(userA.isPersonal)
        #expect(!userA.isOrganization)
        #expect(userA.repos.map(\.name) == ["Alpha", "zeta"])
        #expect(userA.problem == nil)

        let example = try Self.owner("Example-Org", in: owners)
        #expect(example.isOrganization)
        #expect(example.isTruncated)
        #expect(example.accountLogin == "user-a")
        let service = try #require(example.repos.first)
        #expect(service.isImported)
        #expect(service.isArchived)
        #expect(service.badges == [.archived])
        #expect(!userA.repos[0].isImported)
        #expect(userA.repos[0].badges == [.private])

        let other = try Self.owner("Other-Owner", in: owners)
        #expect(!other.isOrganization, "a person whose repository was added by name")
        #expect(other.repos.map(\.fullName) == ["Other-Owner/shared"])

        #expect(try Self.owner("Locked-Org", in: owners).problem == .ssoRequired(nil))
        #expect(try Self.owner("user-b", in: owners).problem == .missingScopes(["repo", "read:org"]))
        let userZ = try Self.owner("user-z", in: owners)
        #expect(userZ.problem == .signedOut)
        #expect(userZ.repos.map(\.fullName) == ["user-z/legacy"])
    }

    @Test func organizationsComeBeforePeople() throws {
        var input = try Self.input()
        let catalog = try #require(input.catalogs["user-a"])
        input.catalogs["user-a"] = AccountCatalogModel(
            accountLogin: "user-a",
            owners: catalog.owners + [OwnerCatalogModel(
                login: "Zulu-Org",
                ownerType: .organization,
                repositories: [try Self.listed("Zulu-Org", "api")],
                failure: nil,
                isTruncated: false
            )],
            organizationsFailure: nil
        )
        let owners = SidebarGrouping.owners(input, query: "")
        #expect(owners.map(\.login) == ["Example-Org", "Locked-Org", "Zulu-Org", "Other-Owner", "user-a", "user-b", "user-z"])
    }

    /// 1.0 (D6c1): no account level. An owner two accounts list shows once, through the account
    /// that imported it; a repository only the other account lists goes through that one.
    @Test func ownerTwoAccountsSeeShowsOnceThroughItsImporter() throws {
        var input = try Self.input()
        input.accounts = [Self.summary("user-b"), Self.summary("user-a")]
        input.catalogs["user-b"] = AccountCatalogModel(
            accountLogin: "user-b",
            owners: [OwnerCatalogModel(
                login: "Example-Org",
                ownerType: .organization,
                repositories: [try Self.listed("Example-Org", "service"), try Self.listed("Example-Org", "web")],
                failure: nil,
                isTruncated: false
            )],
            organizationsFailure: nil
        )
        let owners = SidebarGrouping.owners(input, query: "")
        #expect(owners.filter { $0.login == "Example-Org" }.count == 1)
        let example = try Self.owner("Example-Org", in: owners)
        #expect(example.accountLogin == "user-a", "user-a imported Service")
        #expect(example.repos.map(\.name) == ["Service", "web"])
        #expect(example.repos.map(\.accountLogin) == ["user-a", "user-b"])
        let ids = owners.flatMap(\.repos).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func ownerNotInTheVaultGoesThroughTheFirstSignedInAccountThatListsIt() throws {
        var input = try Self.input()
        input.vaultRepos = []
        input.accounts = [Self.summary("user-b", loggedIn: false), Self.summary("user-c"), Self.summary("user-a")]
        let shared = OwnerCatalogModel(
            login: "Example-Org",
            ownerType: .organization,
            repositories: [try Self.listed("Example-Org", "service")],
            failure: nil,
            isTruncated: false
        )
        for login in ["user-b", "user-c"] {
            input.catalogs[login] = AccountCatalogModel(accountLogin: login, owners: [shared], organizationsFailure: nil)
        }
        let example = try Self.owner("Example-Org", in: SidebarGrouping.owners(input, query: ""))
        #expect(example.accountLogin == "user-c", "user-b is not logged in")
        #expect(example.problem == nil)
    }

    @Test func organizationAccessBecomesTheOwnersSubline() throws {
        var input = try Self.input()
        let url = try #require(URL(string: "https://github.com/orgs/Example-Org/sso"))
        input.organizationAccess["user-a"] = [OrgAccessModel(login: "example-org", status: .needsAdminOrgScope)]
        #expect(try Self.owner("Example-Org", in: SidebarGrouping.owners(input, query: "")).problem == .needsAdminOrg)
        input.organizationAccess["user-a"] = [OrgAccessModel(login: "example-org", status: .needsOrgAdmin)]
        #expect(try Self.owner("Example-Org", in: SidebarGrouping.owners(input, query: "")).problem == .needsOrgAdmin)
        input.organizationAccess["user-a"] = [OrgAccessModel(login: "example-org", status: .ssoRequired(url))]
        #expect(try Self.owner("Example-Org", in: SidebarGrouping.owners(input, query: "")).problem == .ssoRequired(url))
        input.organizationAccess["user-a"] = [OrgAccessModel(login: "example-org", status: .ready)]
        #expect(try Self.owner("Example-Org", in: SidebarGrouping.owners(input, query: "")).problem == nil)
    }

    /// "Org secrets need an org admin" only where those secrets would be read: an imported or a
    /// selected organization, not under every organization the account is a member of.
    @Test func memberOnlySublineShowsOnAnImportedOrSelectedOrganization() throws {
        var input = try Self.input()
        input.organizationAccess["user-a"] = [OrgAccessModel(login: "example-org", status: .needsOrgAdmin)]
        let listed = try Self.owner("Example-Org", in: SidebarGrouping.owners(input, query: ""))
        #expect(SidebarGrouping.shownProblem(of: listed, isSelected: false) == nil)
        #expect(SidebarGrouping.shownProblem(of: listed, isSelected: true) == .needsOrgAdmin)

        input.vaultOrganizations = [OrganizationModel(
            login: "Example-Org",
            accountLogin: "user-a",
            createdAt: ManualClock.defaultStart,
            updatedAt: ManualClock.defaultStart
        )]
        let imported = try Self.owner("Example-Org", in: SidebarGrouping.owners(input, query: ""))
        #expect(SidebarGrouping.shownProblem(of: imported, isSelected: false) == .needsOrgAdmin)

        // A problem the user can fix shows wherever it is.
        input.vaultOrganizations = []
        input.organizationAccess["user-a"] = [OrgAccessModel(login: "example-org", status: .needsAdminOrgScope)]
        let needsScope = try Self.owner("Example-Org", in: SidebarGrouping.owners(input, query: ""))
        #expect(SidebarGrouping.shownProblem(of: needsScope, isSelected: false) == .needsAdminOrg)
    }

    @Test func showMoreHoldsTheRepositoriesNotInTheVault() throws {
        var input = try Self.input()
        input.vaultRepos.append(Self.vaultRepo(account: "user-a", owner: "user-a", name: "zeta"))
        let userA = try Self.owner("user-a", in: SidebarGrouping.owners(input, query: ""))
        let alpha = try #require(userA.repos.first { $0.name == "Alpha" })

        let collapsed = SidebarGrouping.repoList(of: userA, selectedRowID: nil, showsAll: false)
        #expect(collapsed.shown.map(\.name) == ["zeta"])
        #expect(collapsed.hiddenCount == 1)
        let selected = SidebarGrouping.repoList(of: userA, selectedRowID: alpha.id, showsAll: false)
        #expect(selected.shown.map(\.name) == ["Alpha", "zeta"], "the selected repository always shows")
        #expect(selected.hiddenCount == 0)
        let all = SidebarGrouping.repoList(of: userA, selectedRowID: nil, showsAll: true)
        #expect(all.shown.map(\.name) == ["Alpha", "zeta"])
        #expect(all.hiddenCount == 0)
    }

    @Test func searchKeepsMatchingRepositoriesOnly() throws {
        let owners = SidebarGrouping.owners(try Self.input(), query: "SERV")
        #expect(owners.map(\.login) == ["Example-Org"])
        #expect(owners[0].repos.map(\.name) == ["Service"])

        #expect(SidebarGrouping.owners(try Self.input(), query: "nothing-matches").isEmpty)
        // Search matches the owner too.
        let byOwner = SidebarGrouping.owners(try Self.input(), query: "other-owner/")
        #expect(byOwner.flatMap(\.repos).map(\.name) == ["shared"])
    }

    // MARK: - View model over the vault

    @Test func vaultRepositoriesAppearWithoutGH() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let sidebar = SidebarViewModel(app: harness.app)
        let id = try await harness.stageRepository()
        let appeared = await TestFixtures.eventually { sidebar.input.vaultRepos.contains { $0.id == id } }
        #expect(appeared)
        let row = try #require(sidebar.owners.flatMap(\.repos).first)
        #expect(row.importedRepoID == id)
        #expect(row.badges == [.notOnGitHub, .private])
        #expect(!sidebar.canClone(row))
        #expect(sidebar.canRemove(row))

        sidebar.selectedRowID = row.id
        sidebar.searchText = "no-match"
        #expect(sidebar.selectedRepo?.importedRepoID == id)
    }

    /// 1.0 D6c6 (board Main2-Repository): Azure › subscription › vault. A vault imported before
    /// subscriptions were saved stays directly under Azure; a subscription matches the search.
    @Test func keyVaultsGroupUnderTheirSubscription() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let sidebar = SidebarViewModel(app: harness.app)
        let production = KeyVaultSubscriptionModel(id: UUID(), name: "Example Production")
        let development = KeyVaultSubscriptionModel(id: UUID(), name: "Example Development")
        func vault(_ name: String, _ subscription: KeyVaultSubscriptionModel?) throws -> DestinationID {
            try harness.data.destinations.createDestination(
                repositoryID: nil,
                target: .azureKeyVault(vaultName: name, tenantID: nil),
                stage: nil,
                subscription: subscription
            )
        }
        let prod = try vault("kv-example-prod", production)
        let legacy = try vault("kv-example-legacy", nil)
        let dev = try vault("kv-example-dev", development)
        let shared = try vault("kv-example-shared", production)
        #expect(await TestFixtures.eventually { sidebar.keyVaults.count == 4 })

        let azure = sidebar.visibleAzure
        #expect(azure.ungrouped.map(\.id) == [legacy])
        #expect(azure.subscriptions.map(\.subscription) == [development, production], "by name")
        #expect(azure.subscriptions.map { $0.vaults.map(\.id) } == [[dev], [prod, shared]])

        #expect(sidebar.isExpanded(subscription: production.id), "open, as on the board")
        sidebar.toggle(subscription: production.id)
        #expect(!sidebar.isExpanded(subscription: production.id))
        sidebar.searchText = "production"
        #expect(sidebar.isExpanded(subscription: production.id), "a search opens every subscription")
        #expect(sidebar.visibleAzure.subscriptions.map { $0.vaults.map(\.id) } == [[prod, shared]])
        #expect(sidebar.visibleAzure.ungrouped.isEmpty)
        sidebar.searchText = ""
        #expect(!sidebar.isExpanded(subscription: production.id))
        sidebar.toggle(subscription: production.id)
        #expect(sidebar.isExpanded(subscription: production.id))

        // A jump into a closed subscription (⌘K, a linked copy's place) opens it.
        sidebar.toggle(subscription: production.id)
        sidebar.select(keyVaultID: shared)
        #expect(sidebar.isExpanded(subscription: production.id), "the selected vault shows")
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
        #expect(await TestFixtures.eventually { !sidebar.owners.isEmpty })
        let row = try #require(sidebar.owners.flatMap(\.repos).first)

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
        harness.runner.respond(argumentsPrefix: ["api"]) { invocation in
            invocation.arguments.last == "user/memberships/orgs/Example-Org"
                ? .success(#"{"state":"active","role":"admin"}"#)
                : .failure(stderr: "HTTP 404: Not Found")
        }
        let sidebar = SidebarViewModel(app: harness.app)
        await sidebar.reload()
        #expect(sidebar.accountsError == nil)
        #expect(sidebar.owners.map(\.login) == ["Example-Org", "user-a", "user-b"])
        #expect(sidebar.owners[0].accountLogin == "user-a")
        #expect(sidebar.owners[2].problem == .missingScopes(["repo", "read:org"]))
        // The organization access arrives after the tree (user-a lacks admin:org).
        #expect(await TestFixtures.eventually { sidebar.owners.first?.problem == .needsAdminOrg })
    }

    /// 1.0 (D6c1): owners start collapsed; a selection opens the owner above it, a search opens
    /// every owner, and ⌘F asks the search field for the focus.
    @Test func ownersExpandForTheSelectionAndTheSearch() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let sidebar = SidebarViewModel(app: harness.app)
        let id = try await harness.stageRepository()
        #expect(await TestFixtures.eventually { sidebar.input.vaultRepos.contains { $0.id == id } })
        let owner = try #require(sidebar.owners.first)
        #expect(!sidebar.isExpanded(owner))

        sidebar.searchText = "repo"
        #expect(sidebar.isExpanded(owner))
        sidebar.searchText = ""
        #expect(!sidebar.isExpanded(owner))

        sidebar.toggle(owner)
        #expect(sidebar.isExpanded(owner))
        sidebar.toggle(owner)
        #expect(!sidebar.isExpanded(owner))

        sidebar.selectedRowID = try #require(owner.repos.first).id
        #expect(sidebar.isExpanded(owner))

        let request = sidebar.searchFocusRequest
        sidebar.focusSearch()
        #expect(sidebar.searchFocusRequest == request + 1)
    }

    /// A ⌘F the field could not take in time is dropped: it must not grab the focus the next
    /// time the sidebar shows, maybe minutes later.
    @Test func aFocusRequestTheFieldCouldNotTakeIsDropped() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let sidebar = SidebarViewModel(app: harness.app)
        sidebar.focusSearch()
        #expect(sidebar.isSearchFocusPending)

        sidebar.cancelSearchFocus()
        #expect(!sidebar.isSearchFocusPending)
    }
}
