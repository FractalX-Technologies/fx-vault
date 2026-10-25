import Foundation
import GitHubKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// An organization's own secrets and variables in the main window (tasks/todo.md B5c): its row
/// in the sidebar, Import, the read-only detail and Remove from Vault.
@MainActor
@Suite("Organizations")
struct OrganizationViewModelTests {
    static let ready = MainViewModelTests.ready

    static let secrets = """
    [{"name":"STRIPE_KEY","numSelectedRepos":3,"updatedAt":"2026-10-12T10:00:00Z","visibility":"selected"},
     {"name":"NPM_TOKEN","numSelectedRepos":0,"updatedAt":"2026-08-02T10:00:00Z","visibility":"all"}]
    """
    static let variables = """
    [{"createdAt":"2026-08-01T10:00:00Z","name":"REGION","numSelectedRepos":0,"updatedAt":"2026-08-02T10:00:00Z","value":"eu-west","visibility":"private"}]
    """

    static func organization(_ login: String, account: String = "user-a") -> OrganizationModel {
        OrganizationModel(login: login, accountLogin: account, secretCount: 2, variableCount: 1, createdAt: ManualClock.defaultStart, updatedAt: ManualClock.defaultStart)
    }

    /// The Example-Org node (through user-a), before or after its import.
    static func owner(organization: OrganizationModel? = nil) -> SidebarOwnerModel {
        SidebarOwnerModel(
            id: "example-org",
            login: "Example-Org",
            accountLogin: "user-a",
            ownerType: .organization,
            isPersonal: false,
            isTruncated: false,
            repos: [],
            organization: organization,
            problem: nil
        )
    }

    /// A live gh status over the scripted gh (a fixed status has no gh to run the lists with).
    func scriptLists(_ harness: TestHarness) async throws {
        try harness.installFakeGH()
        harness.stubAuthStatus(TestFixtures.authStatusTwoAccounts)
        harness.stubToken()
        harness.runner.stub(argumentsPrefix: ["secret", "list", "--org=Example-Org"], with: .success(Self.secrets))
        harness.runner.stub(argumentsPrefix: ["variable", "list", "--org=Example-Org"], with: .success(Self.variables))
        await harness.app.refreshGHStatus()
    }

    // MARK: - Grouping

    @Test func importedOrganizationsJoinTheirGroupAndStayFindable() throws {
        var input = try SidebarViewModelTests.input()
        let example = Self.organization("example-org")
        input.vaultOrganizations = [example, Self.organization("Gone-Org")]

        let owners = SidebarGrouping.owners(input, query: "")
        let exampleGroup = try #require(owners.first { $0.login == "Example-Org" })
        #expect(exampleGroup.organization == example)
        #expect(exampleGroup.isOrganization)
        #expect(exampleGroup.accountLogin == "user-a")
        // An organization in the vault that gh no longer lists keeps its group, with no repositories.
        let gone = try #require(owners.first { $0.login == "Gone-Org" })
        #expect(gone.repos.isEmpty)
        #expect(gone.organization != nil)
        #expect(owners.first { $0.login == "Locked-Org" }?.organization == nil)
        #expect(owners.first { $0.login == "user-a" }?.isOrganization == false)

        // Searching its login keeps an imported organization even without matching repositories.
        let found = SidebarGrouping.owners(input, query: "gone")
        #expect(found.map(\.login) == ["Gone-Org"])
    }

    @Test func visibilityTitles() {
        #expect(OrgVisibility.all.title(selectedCount: nil) == "All repositories")
        #expect(OrgVisibility.private.title(selectedCount: nil) == "Private and internal repositories")
        #expect(OrgVisibility.selected.title(selectedCount: 3) == "Selected · 3 repositories")
        #expect(OrgVisibility.selected.title(selectedCount: nil) == "Selected repositories")
        #expect(OrganizationCopy.counts(secrets: 2, variables: 1, withoutValue: 0) == "2 secrets · 1 variables")
        #expect(OrganizationCopy.counts(secrets: 2, variables: 1, withoutValue: 2) == "2 secrets · 1 variables · 2 without value")
    }

    // MARK: - Selection and import

    @Test func oneSelectionAtATime() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let sidebar = SidebarViewModel(app: harness.app)
        sidebar.selectedRowID = "example-org/service"

        sidebar.select(organization: Self.owner())
        #expect(sidebar.selectedOrganizationOwnerID == "example-org")
        #expect(sidebar.selectedRowID == nil)

        sidebar.selectedFolderID = FolderID()
        #expect(sidebar.selectedOrganizationOwnerID == nil)
        sidebar.select(organization: Self.owner())
        #expect(sidebar.selectedFolderID == nil)
        sidebar.selectedRowID = "example-org/service"
        #expect(sidebar.selectedOrganizationOwnerID == nil)
    }

    @Test func importNeedsGitHubAndAnUnlockedVault() async throws {
        let notReady = try await TestHarness(vault: .unlocked)
        #expect(!SidebarViewModel(app: notReady.app).canImportOrganization(Self.owner()))
        let locked = try await TestHarness(vault: .locked, ghStatus: Self.ready)
        #expect(!SidebarViewModel(app: locked.app).canImportOrganization(Self.owner()))

        let harness = try await TestHarness(vault: .unlocked, ghStatus: Self.ready)
        let sidebar = SidebarViewModel(app: harness.app)
        #expect(sidebar.canImportOrganization(Self.owner()))
        #expect(!sidebar.canImportOrganization(Self.owner(organization: Self.organization("example-org"))))
    }

    @Test func importShowsTheReadOnlyDetailAndRemoveClearsIt() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        try await scriptLists(harness)
        let main = harness.app.makeMainViewModel()
        let sidebar = main.sidebar
        sidebar.select(organization: Self.owner())
        #expect(main.organizationDetail == nil)
        #expect(main.detail == nil)

        await sidebar.importOrganization(Self.owner())

        #expect(sidebar.alert == nil)
        #expect(sidebar.notice == "Imported Example-Org: 2 secrets, 1 variables.")
        #expect(await TestFixtures.eventually { sidebar.input.vaultOrganizations.count == 1 })
        let organization = try #require(sidebar.input.vaultOrganizations.first)
        #expect(sidebar.vaultOrganization(organization.id) == organization)

        // The selected group is now imported: the detail column follows.
        #expect(await TestFixtures.eventually { main.organizationDetail != nil })
        let detail = try #require(main.organizationDetail)
        #expect(detail.organizationID == organization.id)
        #expect(await TestFixtures.eventually { detail.items.count == 3 })
        #expect(detail.rows.map(\.name) == ["NPM_TOKEN", "STRIPE_KEY", "REGION"])
        #expect(detail.counts == "2 secrets · 1 variables · 2 without value")
        #expect(detail.organization?.login == "Example-Org")

        sidebar.requestRemoval(organization)
        #expect(sidebar.pendingOrganizationRemoval == organization)
        await sidebar.confirmOrganizationRemoval()
        #expect(await TestFixtures.eventually { sidebar.input.vaultOrganizations.isEmpty })
        #expect(await TestFixtures.eventually { main.organizationDetail == nil })
    }
}
