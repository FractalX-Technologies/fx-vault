import Foundation
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

/// Local changes to organization items (1.0, tasks/todo.md B6b): what becomes pending, the
/// repository lists, deletions, revert and validation.
@Suite("OrganizationItemRepository")
struct OrganizationItemRepositoryTests {
    struct Fixture {
        let base: OrganizationRepositoryTests.Fixture
        let items: OrganizationItemRepository
        let organization: OrganizationModel

        static func make() async throws -> Fixture {
            let base = try await OrganizationRepositoryTests.Fixture.make()
            base.scriptLists()
            let result = try await base.organizations.importOrganization(
                login: OrganizationRepositoryTests.organization,
                accountLogin: ConfigFixture.login
            )
            return Fixture(
                base: base,
                items: OrganizationItemRepository(session: base.harness.session, clock: base.harness.clock),
                organization: result.organization
            )
        }

        func item(_ name: String, _ kind: ConfigKind = .secret) async throws -> OrgItemModel {
            try #require(try await base.organizations.items(of: organization.id).first { $0.name == name && $0.kind == kind })
        }

        func value(_ text: String) -> SecretBytes {
            SecretBytes(utf8: text)
        }
    }

    @Test func importedItemsAreSyncedAndEditsBecomePending() async throws {
        let fixture = try await Fixture.make()
        let items = fixture.items
        #expect(try await fixture.base.organizations.items(of: fixture.organization.id).allSatisfy { $0.syncStatus == .synced })
        #expect(try items.pendingCounts().isEmpty)

        let region = try await fixture.item("REGION", .variable)
        let result = try items.setValue(region.id, value: fixture.value("eu-north\n"))
        #expect(result.didStripTrailingNewlines)
        #expect(try await fixture.item("REGION", .variable).syncStatus == .modified)

        let npm = try await fixture.item("NPM_TOKEN")
        try items.setAccess(npm.id, .selected(["api", "web"]))
        let selected = try await fixture.item("NPM_TOKEN")
        #expect(selected.visibility == .selected && selected.selectedRepositoryCount == 2)
        #expect(selected.syncStatus == .modified)
        #expect(try items.repositories(of: npm.id) == ["api", "web"])

        // A secret value filled in to match GitHub is not pushed.
        let stripe = try await fixture.item("STRIPE_KEY")
        try items.setValue(stripe.id, value: fixture.value("FXV_FIXTURE_SECRET"), alreadyMatchesRemote: true)
        #expect(try await fixture.item("STRIPE_KEY").syncStatus == .synced)
        #expect(try fixture.base.reveal(try fixture.base.record("STRIPE_KEY", kind: .secret, of: fixture.organization.id)) == "FXV_FIXTURE_SECRET")
        #expect(try items.pendingCounts() == [fixture.organization.id: 2])

        try items.revertItems([npm.id])
        let reverted = try await fixture.item("NPM_TOKEN")
        #expect(reverted.visibility == .all && reverted.syncStatus == .synced)
        #expect(try items.repositories(of: npm.id).isEmpty)

        // A new list for an item that stays `selected` is a change too.
        try items.setAccess(stripe.id, .selected(["api"]))
        #expect(try await fixture.item("STRIPE_KEY").syncStatus == .modified)
    }

    /// B7a: a repository inherits the live items whose visibility reaches it. The fixture's
    /// NPM_TOKEN reaches all, FXV_FIXTURE_URL private repositories; STRIPE_KEY and REGION are
    /// `selected` with lists FX Vault never read, so they reach nothing.
    @Test func aRepositoryInheritsWhatItsOrganizationGivesIt() async throws {
        let fixture = try await Fixture.make()
        let organizations = fixture.base.organizations
        let login = OrganizationRepositoryTests.organization
        let web = try #require(try await organizations.inheritedItems(ownerLogin: login, repositoryName: "web", isPrivate: false))
        #expect(web.organizationLogin == login)
        #expect(web.organizationID == fixture.organization.id)
        #expect(web.items.map(\.name) == ["NPM_TOKEN"])
        let api = try await organizations.inheritedItems(ownerLogin: login.uppercased(), repositoryName: "api", isPrivate: true)
        #expect(api?.items.map(\.name) == ["FXV_FIXTURE_URL", "NPM_TOKEN"], "the owner's login matches without case")

        // A stored list names the repository (in any case); a pending deletion gives nothing.
        let stripe = try await fixture.item("STRIPE_KEY")
        try fixture.items.setAccess(stripe.id, .selected(["API"]))
        let npm = try await fixture.item("NPM_TOKEN")
        try fixture.items.deleteItems([npm.id])
        #expect(try await organizations.inheritedItems(ownerLogin: login, repositoryName: "api", isPrivate: true)?.items.map(\.name) == ["FXV_FIXTURE_URL", "STRIPE_KEY"])
        #expect(try await organizations.inheritedItems(ownerLogin: login, repositoryName: "web", isPrivate: false)?.items.isEmpty == true)

        #expect(try await organizations.inheritedItems(ownerLogin: "other-org", repositoryName: "api", isPrivate: true) == nil)
    }

    @Test func addsDeletionsAndRevivals() async throws {
        let fixture = try await Fixture.make()
        let items = fixture.items
        let id = fixture.organization.id
        let added = try items.addItem(organizationID: id, kind: .secret, name: "deploy_key", value: fixture.value("FXV_FIXTURE_SECRET"), access: .private)
        let deploy = try await fixture.item("DEPLOY_KEY")
        #expect(deploy.id == added.itemID && deploy.syncStatus == .added && deploy.visibility == .private)
        #expect(throws: ConfigRepositoryError.validation(.duplicateName)) {
            try items.addItem(organizationID: id, kind: .secret, name: "DEPLOY_KEY", value: fixture.value("x"), access: .all)
        }

        // Deleting an add removes it; deleting a synced item waits for Sync.
        try items.deleteItems([added.itemID])
        #expect(try await fixture.base.organizations.items(of: id).contains { $0.name == "DEPLOY_KEY" } == false)
        let npm = try await fixture.item("NPM_TOKEN")
        try items.deleteItems([npm.id])
        #expect(try await fixture.item("NPM_TOKEN").syncStatus == .deleted)
        #expect(throws: ConfigRepositoryError.itemNotFound) { try items.setValue(npm.id, value: fixture.value("x")) }

        // Adding the name again revives the row, with the new value pending.
        let revived = try items.addItem(organizationID: id, kind: .secret, name: "NPM_TOKEN", value: fixture.value("FXV_FIXTURE_SECRET"), access: .all)
        #expect(revived.itemID == npm.id)
        #expect(try await fixture.item("NPM_TOKEN").syncStatus == .modified)

        try items.deleteItems([npm.id])
        try items.revertItems([npm.id])
        #expect(try await fixture.item("NPM_TOKEN").syncStatus == .modified, "Revert keeps a changed value")
    }

    @Test func listsNamesAndOrganizationsAreValidated() async throws {
        let fixture = try await Fixture.make()
        let items = fixture.items
        let id = fixture.organization.id
        #expect(throws: ConfigRepositoryError.validation(.invalidName(.empty))) {
            try items.addItem(organizationID: id, kind: .variable, name: "A_VAR", value: fixture.value("a"), access: .selected([]))
        }
        #expect(throws: ConfigRepositoryError.validation(.duplicateName)) {
            try items.addItem(organizationID: id, kind: .variable, name: "A_VAR", value: fixture.value("a"), access: .selected(["api", "API"]))
        }
        #expect(throws: ConfigRepositoryError.organizationNotFound) {
            try items.addItem(organizationID: OrganizationID(), kind: .variable, name: "A_VAR", value: fixture.value("a"), access: .all)
        }
        let npm = try await fixture.item("NPM_TOKEN")
        #expect(throws: ConfigRepositoryError.valueMissing) { try items.reveal(npm.id) }
        #expect(try await fixture.base.organizations.items(of: id).contains { $0.name == "A_VAR" } == false)
    }
}
