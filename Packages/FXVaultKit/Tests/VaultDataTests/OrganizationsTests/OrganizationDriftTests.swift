import Foundation
import GitHubKit
import SyncEngine
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// Organization Refresh (1.0, tasks/todo.md B7b) over scripted gh: what counts as changed on
/// GitHub, and Keep Local / Accept GitHub for each kind of difference.
@Suite("OrganizationDrift")
struct OrganizationDriftTests {
    /// The imported example-org with a local add of API_TOKEN and a pending deletion of
    /// FXV_FIXTURE_URL.
    static func fixture() async throws -> OrganizationItemRepositoryTests.Fixture {
        let fixture = try await OrganizationItemRepositoryTests.Fixture.make()
        _ = try fixture.items.addItem(
            organizationID: fixture.organization.id,
            kind: .secret,
            name: "API_TOKEN",
            value: fixture.value("FXV_FIXTURE_SECRET"),
            access: .all
        )
        try fixture.items.deleteItems([try await fixture.item("FXV_FIXTURE_URL", .variable).id])
        return fixture
    }

    // gitleaks:allow (secret names only, no values)
    /// GitHub now: NPM_TOKEN changed (date), STRIPE_KEY reaches 4 repositories (same date),
    /// API_TOKEN and DEPLOY_KEY added there, REGION and FXV_FIXTURE_URL deleted there.
    static let changedSecrets = """
    [{"name":"API_TOKEN","numSelectedRepos":0,"updatedAt":"2026-10-25T12:00:00Z","visibility":"all"},
     {"name":"DEPLOY_KEY","numSelectedRepos":0,"updatedAt":"2026-10-25T12:00:00Z","visibility":"private"},
     {"name":"NPM_TOKEN","numSelectedRepos":0,"updatedAt":"2026-10-20T10:00:00Z","visibility":"all"},
     {"name":"STRIPE_KEY","numSelectedRepos":4,"updatedAt":"2026-10-12T10:00:00Z","visibility":"selected"},
     {"name":"1FXV_FIXTURE_BAD","numSelectedRepos":0,"updatedAt":"2026-08-02T10:00:00Z","visibility":"private"}]
    """
    static let changedVariables = "[]"

    static func scriptChanged(_ fixture: OrganizationItemRepositoryTests.Fixture) {
        fixture.base.scriptLists(secrets: changedSecrets, variables: changedVariables)
    }

    @Test func refreshFindsWhatChangedOnGitHubAndFinishesDeletionsItAlreadyHas() async throws {
        let fixture = try await Self.fixture()
        let organizations = fixture.base.organizations
        let id = fixture.organization.id
        Self.scriptChanged(fixture)

        let refresh = try await organizations.refresh(organizationID: id)

        #expect(refresh.findings.map(\.name) == ["API_TOKEN", "DEPLOY_KEY", "NPM_TOKEN", "REGION", "STRIPE_KEY"])
        #expect(refresh.findings.map(\.kind) == [.remoteAdded, .remoteAdded, .secretModified, .remoteDeleted, .secretModified])
        let byName = Dictionary(uniqueKeysWithValues: refresh.findings.map { ($0.name, $0) })
        // Both sides added API_TOKEN: a conflict on the vault's row.
        let api = try await fixture.item("API_TOKEN")
        #expect(byName["API_TOKEN"]?.itemID == api.id)
        #expect(byName["API_TOKEN"]?.isConflict == true)
        #expect(byName["API_TOKEN"]?.hasLocalValue == true && byName["API_TOKEN"]?.canKeepLocal == true)
        #expect(byName["DEPLOY_KEY"]?.itemID == nil)
        // A secret GitHub changed cannot be kept without its value; a variable has one.
        #expect(byName["NPM_TOKEN"]?.canKeepLocal == false)
        let npm = try await fixture.item("NPM_TOKEN")
        #expect(byName["NPM_TOKEN"]?.remoteUpdatedAt != npm.remoteUpdatedAt)
        #expect(byName["REGION"]?.canKeepLocal == true)
        #expect(byName["STRIPE_KEY"]?.isConflict == false)
        #expect(refresh.changedItemIDs.count == 4)
        #expect(refresh.skippedNames.map(\.name) == ["1FXV_FIXTURE_BAD"])
        #expect(refresh.listedAt == fixture.base.harness.clock.now)

        // The pending deletion GitHub no longer has is done; the refresh date is recorded.
        let names = try await organizations.items(of: id).map(\.name)
        #expect(!names.contains("FXV_FIXTURE_URL"))
        #expect(try await organizations.organizations().first?.lastRefreshedAt == fixture.base.harness.clock.now)

        // An unchanged listing finds nothing, also for a list edit undone (its count is unknown).
        let fresh = try await OrganizationItemRepositoryTests.Fixture.make()
        let stripe = try await fresh.item("STRIPE_KEY")
        try fresh.items.setAccess(stripe.id, .selected(["api"]))
        try fresh.items.revertItems([stripe.id])
        #expect(try await fresh.item("STRIPE_KEY").selectedRepositoryCount == nil)
        fresh.base.scriptLists()
        #expect(try await fresh.base.organizations.refresh(organizationID: fresh.organization.id).findings.isEmpty)
    }

    @Test func acceptGitHubTakesItsItemAndKeepLocalLeavesTheVaultsPending() async throws {
        let fixture = try await Self.fixture()
        let organizations = fixture.base.organizations
        let id = fixture.organization.id
        // STRIPE_KEY's value was filled in to match GitHub; GitHub changes only its count.
        try fixture.items.setValue(try await fixture.item("STRIPE_KEY").id, value: fixture.value("FXV_FIXTURE_SECRET"), alreadyMatchesRemote: true)
        Self.scriptChanged(fixture)
        let all = try await organizations.refresh(organizationID: id).findings
        func findings(_ names: String...) -> [OrgDriftModel] {
            all.filter { names.contains($0.name) }
        }

        // Keep Local of a secret GitHub changed needs its value: refused before GitHub is read.
        await #expect(throws: DriftRepositoryError.resolutionUnavailable(.valueMissing)) {
            try await organizations.resolve(findings("NPM_TOKEN"), option: .keepLocal, organizationID: id)
        }

        // Accept GitHub: a secret whose date moved loses its value; one whose date stands keeps it.
        try fixture.items.setValue(try await fixture.item("NPM_TOKEN").id, value: fixture.value("FXV_FIXTURE_SECRET"), alreadyMatchesRemote: true)
        Self.scriptChanged(fixture)
        try await organizations.resolve(findings("NPM_TOKEN", "STRIPE_KEY", "DEPLOY_KEY"), option: .acceptGitHub, organizationID: id)
        let npm = try await fixture.item("NPM_TOKEN")
        #expect(npm.syncStatus == .synced)
        #expect(npm.remoteUpdatedAt == findings("NPM_TOKEN").first?.remoteUpdatedAt)
        #expect(!npm.hasValue)
        let stripe = try await fixture.item("STRIPE_KEY")
        #expect(stripe.selectedRepositoryCount == 4)
        #expect(stripe.syncStatus == .synced)
        #expect(stripe.hasValue)
        let deploy = try await fixture.item("DEPLOY_KEY")
        #expect(deploy.visibility == .private && deploy.syncStatus == .synced && !deploy.hasValue)

        // Keep Local: the vault's add becomes an update over GitHub's item, and the item GitHub
        // deleted becomes an add again.
        Self.scriptChanged(fixture)
        try await organizations.resolve(findings("API_TOKEN", "REGION"), option: .keepLocal, organizationID: id)
        let api = try await fixture.item("API_TOKEN")
        #expect(api.syncStatus == .modified)
        #expect(api.hasValue)
        #expect(try await fixture.item("REGION", .variable).syncStatus == .added)

        // Nothing is left to review; a finding that no longer holds is refused.
        Self.scriptChanged(fixture)
        #expect(try await organizations.refresh(organizationID: id).findings.isEmpty)
        Self.scriptChanged(fixture)
        await #expect(throws: DriftRepositoryError.stale) {
            try await organizations.resolve(findings("DEPLOY_KEY"), option: .acceptGitHub, organizationID: id)
        }
    }

    /// Only a moved date or visibility, or the count of a list FX Vault doesn't hold, is a
    /// change; a pending deletion GitHub still lists stays pending.
    @Test func aChangeIsADateVisibilityOrGitHubsCountAndAPendingDeletionStays() async throws {
        let fixture = try await OrganizationItemRepositoryTests.Fixture.make()
        let id = fixture.organization.id
        try fixture.items.deleteItems([try await fixture.item("REGION", .variable).id])
        // An edited list's count is the vault's own, not GitHub's.
        try fixture.items.setAccess(try await fixture.item("STRIPE_KEY").id, .selected(["api"]))
        // NPM_TOKEN: only its visibility changed, under the same date.
        let secrets = """
        [{"name":"NPM_TOKEN","numSelectedRepos":0,"updatedAt":"2026-08-02T10:00:00Z","visibility":"private"},
         {"name":"STRIPE_KEY","numSelectedRepos":3,"updatedAt":"2026-10-12T10:00:00Z","visibility":"selected"}]
        """
        fixture.base.scriptLists(secrets: secrets)

        let findings = try await fixture.base.organizations.refresh(organizationID: id).findings

        #expect(findings.map(\.name) == ["NPM_TOKEN"])
        #expect(findings.first?.kind == .secretModified)
        #expect(findings.first?.isRemoteDateChanged == false)
        #expect(try await fixture.item("REGION", .variable).syncStatus == .deleted)
    }

    /// D28: right after this Mac's Sync deleted an item, a listing that still shows it is not an
    /// add on GitHub; once the suppression window has passed, it is.
    @Test func whatSyncJustDeletedIsNotReportedAsAdded() async throws {
        let fixture = try await OrganizationSyncRepositoryTests.Fixture.make()
        let base = fixture.base
        let organizations = base.base.organizations
        let id = fixture.organizationID
        try fixture.items.deleteItems([try await base.item("NPM_TOKEN").id])
        base.base.scriptLists()
        let review = await fixture.sync.review(organizationID: id)
        fixture.scriptWritesSucceed()
        #expect(await fixture.sync.run(review, includeDeletions: true).doneCount == 1)
        #expect(try await organizations.items(of: id).allSatisfy { $0.name != "NPM_TOKEN" })

        base.base.scriptLists()
        #expect(try await organizations.refresh(organizationID: id).findings.isEmpty)
        base.base.harness.clock.advance(by: Timeouts.recentDeletionSuppression + .seconds(1))
        base.base.scriptLists()
        #expect(try await organizations.refresh(organizationID: id).findings.map(\.name) == ["NPM_TOKEN"])
    }

    @Test func keepLocalOfAnItemOnlyGitHubHasStoresItsDeletion() async throws {
        let fixture = try await OrganizationItemRepositoryTests.Fixture.make()
        let organizations = fixture.base.organizations
        let id = fixture.organization.id
        let variables = """
        [{"createdAt":"2026-08-01T10:00:00Z","name":"REGION","numSelectedRepos":2,"updatedAt":"2026-08-02T10:00:00Z","value":"eu-west","visibility":"selected"},
         {"createdAt":"2026-08-01T10:00:00Z","name":"FXV_FIXTURE_URL","numSelectedRepos":0,"updatedAt":"2026-08-02T10:00:00Z","value":"https://example.invalid/api\\n","visibility":"private"},
         {"createdAt":"2026-10-25T10:00:00Z","name":"LOG_LEVEL","numSelectedRepos":0,"updatedAt":"2026-10-25T10:00:00Z","value":"debug","visibility":"all"}]
        """
        fixture.base.scriptLists(variables: variables)
        let added = try await organizations.refresh(organizationID: id).findings
        #expect(added.map(\.name) == ["LOG_LEVEL"])

        fixture.base.scriptLists(variables: variables)
        try await organizations.resolve(added, option: .keepLocal, organizationID: id)

        let level = try await fixture.item("LOG_LEVEL", .variable)
        #expect(level.syncStatus == .deleted)
        // Revert brings back GitHub's item with its value.
        try fixture.items.revertItems([level.id])
        let record = try fixture.base.record("LOG_LEVEL", kind: .variable, of: id)
        #expect(try fixture.base.reveal(record) == "debug")
        #expect(record.syncStatus == .synced)
    }
}
