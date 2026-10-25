import Foundation
import GitHubKit
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

/// Organization import, listing and removal (1.0, tasks/todo.md B5), with scripted gh output,
/// and DEK rotation of organization values.
@Suite("OrganizationRepository")
struct OrganizationRepositoryTests {
    static let organization = "example-org"

    struct Fixture {
        let harness: ConfigHarness
        let provider: FakeSchedulerProvider
        let organizations: OrganizationRepository

        static func make() async throws -> Fixture {
            let harness = try await ConfigHarness.make()
            let provider = FakeSchedulerProvider()
            let organizations = OrganizationRepository(session: harness.session, schedulers: provider, clock: harness.clock)
            return Fixture(harness: harness, provider: provider, organizations: organizations)
        }

        var store: OrganizationStore {
            OrganizationStore(database: harness.database)
        }

        /// Scripts B12 and B13 for ``OrganizationRepositoryTests/organization``.
        func scriptLists(secrets: String = Self.secrets, variables: String = Self.variables) {
            let flag = "--org=\(OrganizationRepositoryTests.organization)"
            provider.runner.enqueue(.success(secrets), matching: { $0.starts(with: ["secret", "list", flag]) })
            provider.runner.enqueue(.success(variables), matching: { $0.starts(with: ["variable", "list", flag]) })
        }

        func record(_ name: String, kind: ConfigKind, of id: OrganizationID) throws -> OrgItemRecord {
            try harness.database.read { tx in
                try #require(try store.fetchItemRecords(organizationID: id, in: tx).first { $0.name == name && $0.kind == kind })
            }
        }

        func reveal(_ record: OrgItemRecord) throws -> String? {
            try harness.session.withKeys { keys in
                let value = try OrgFieldCipher.openValue(of: record, keys: keys)
                defer { value?.wipe() }
                return value?.utf8String()
            }
        }

        // gitleaks:allow (secret names only, no values)
        static let secrets = """
        [{"name":"NPM_TOKEN","numSelectedRepos":0,"updatedAt":"2026-08-02T10:00:00Z","visibility":"all"},
         {"name":"STRIPE_KEY","numSelectedRepos":3,"updatedAt":"2026-10-12T10:00:00Z","visibility":"selected"},
         {"name":"1FXV_FIXTURE_BAD","numSelectedRepos":0,"updatedAt":"2026-08-02T10:00:00Z","visibility":"private"}]
        """
        static let variables = """
        [{"createdAt":"2026-08-01T10:00:00Z","name":"REGION","numSelectedRepos":2,"updatedAt":"2026-08-02T10:00:00Z","value":"eu-west","visibility":"selected"},
         {"createdAt":"2026-08-01T10:00:00Z","name":"FXV_FIXTURE_URL","numSelectedRepos":0,"updatedAt":"2026-08-02T10:00:00Z","value":"https://example.invalid/api\\n","visibility":"private"}]
        """
    }

    // MARK: - Import

    @Test func importStoresSecretsAndVariablesWithTheirVisibility() async throws {
        let fixture = try await Fixture.make()
        fixture.scriptLists()

        let result = try await fixture.organizations.importOrganization(login: Self.organization, accountLogin: ConfigFixture.login)
        let organization = result.organization
        #expect(organization.login == Self.organization)
        #expect(organization.accountLogin == ConfigFixture.login)
        #expect(organization.secretCount == 2)
        #expect(organization.variableCount == 2)
        #expect(organization.lastRefreshedAt == fixture.harness.clock.now)
        #expect(result.skippedNames == [SkippedRemoteNameModel(kind: .item(.secret), environment: nil, name: "1FXV_FIXTURE_BAD")])
        #expect(try await fixture.organizations.organizations() == [organization])

        let items = try await fixture.organizations.items(of: organization.id)
        #expect(items.map(\.name) == ["FXV_FIXTURE_URL", "NPM_TOKEN", "REGION", "STRIPE_KEY"])
        // Secrets have no value; their visibility and GitHub's updatedAt are kept.
        let stripe = try #require(items.first { $0.name == "STRIPE_KEY" })
        #expect(stripe.kind == .secret)
        #expect(stripe.hasValue == false)
        #expect(stripe.visibility == .selected)
        #expect(stripe.selectedRepositoryCount == 3)
        #expect(stripe.remoteUpdatedAt != nil)
        let npm = try #require(items.first { $0.name == "NPM_TOKEN" })
        #expect(npm.visibility == .all)
        #expect(npm.selectedRepositoryCount == nil)

        // Variables open under their own identity, stored exactly as listed (D32), and are synced.
        let region = try fixture.record("REGION", kind: .variable, of: organization.id)
        #expect(try fixture.reveal(region) == "eu-west")
        #expect(region.visibility == .selected)
        #expect(region.selectedCount == 2)
        #expect(region.syncedFingerprint != nil)
        #expect(region.syncedFingerprint == region.valueFingerprint)
        let url = try fixture.record("FXV_FIXTURE_URL", kind: .variable, of: organization.id)
        #expect(try fixture.reveal(url) == "https://example.invalid/api\n")
        #expect(url.selectedCount == nil)
    }

    @Test func importingTheSameOrganizationAgainIsRefused() async throws {
        let fixture = try await Fixture.make()
        fixture.scriptLists()
        let first = try await fixture.organizations.importOrganization(login: Self.organization, accountLogin: ConfigFixture.login)

        let error = await catalogError {
            _ = try await fixture.organizations.importOrganization(login: "Example-ORG", accountLogin: ConfigFixture.login)
        }

        #expect(error == .organizationAlreadyImported(first.organization.id))
        #expect(fixture.provider.runner.invocations.filter { $0.arguments.first == "secret" }.count == 1)
    }

    @Test func aRowWithoutVisibilityStoresNothing() async throws {
        let fixture = try await Fixture.make()
        fixture.scriptLists(secrets: #"[{"name":"NPM_TOKEN","updatedAt":"2026-08-02T10:00:00Z"}]"#)

        let error = await catalogError {
            _ = try await fixture.organizations.importOrganization(login: Self.organization, accountLogin: ConfigFixture.login)
        }

        #expect(error == .github(.malformedOutput))
        #expect(try await fixture.organizations.organizations().isEmpty)
    }

    @Test func aFailedListStoresNothing() async throws {
        let fixture = try await Fixture.make()
        fixture.provider.runner.enqueue(
            .failure(stderr: "gh: Bad credentials (HTTP 401)\n"),
            matching: { $0.starts(with: ["secret", "list", "--org=\(Self.organization)"]) }
        )

        let error = await catalogError {
            _ = try await fixture.organizations.importOrganization(login: Self.organization, accountLogin: ConfigFixture.login)
        }

        #expect(error == .github(.tokenRevoked))
        #expect(try await fixture.organizations.organizations().isEmpty)
    }

    @Test func importNeedsAnUnlockedVault() async throws {
        let fixture = try await Fixture.make()
        fixture.scriptLists()
        fixture.harness.manager.lock()

        let error = await catalogError {
            _ = try await fixture.organizations.importOrganization(login: Self.organization, accountLogin: ConfigFixture.login)
        }

        #expect(error == .vault(.locked))
        #expect(try await fixture.organizations.organizations().isEmpty)
    }

    // MARK: - Remove

    @Test func removingAnOrganizationRemovesItsItems() async throws {
        let fixture = try await Fixture.make()
        fixture.scriptLists()
        let id = try await fixture.organizations.importOrganization(login: Self.organization, accountLogin: ConfigFixture.login).organization.id

        try await fixture.organizations.removeOrganization(id)

        #expect(try await fixture.organizations.organizations().isEmpty)
        #expect(try await fixture.organizations.items(of: id).isEmpty)
        let again = await catalogError { try await fixture.organizations.removeOrganization(id) }
        #expect(again == .organizationNotFound)
    }

    // MARK: - DEK rotation

    @Test func rotationReSealsOrganizationValuesAndKeepsThemSynced() async throws {
        let fixture = try await Fixture.make()
        fixture.scriptLists()
        let id = try await fixture.organizations.importOrganization(login: Self.organization, accountLogin: ConfigFixture.login).organization.id
        let before = try fixture.record("REGION", kind: .variable, of: id)
        // A stale snapshot (the value changed since the last read) cannot be carried over.
        var stale = try fixture.record("FXV_FIXTURE_URL", kind: .variable, of: id)
        stale.syncedFingerprint = Data(repeating: 1, count: 32)
        try fixture.harness.database.write { tx in try fixture.store.updateItem(stale, in: tx) }
        let secret = try fixture.record("STRIPE_KEY", kind: .secret, of: id)

        _ = try await fixture.harness.manager.rotateDEK(password: ConfigFixture.password)

        let after = try fixture.record("REGION", kind: .variable, of: id)
        #expect(after.valueCiphertext != before.valueCiphertext)
        #expect(after.valueFingerprint != before.valueFingerprint)
        #expect(after.syncedFingerprint == after.valueFingerprint)
        #expect(try fixture.reveal(after) == "eu-west")
        #expect(try fixture.record("FXV_FIXTURE_URL", kind: .variable, of: id).syncedFingerprint == nil)
        #expect(try fixture.record("STRIPE_KEY", kind: .secret, of: id) == secret)
    }
}
