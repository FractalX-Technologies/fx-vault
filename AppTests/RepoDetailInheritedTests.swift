import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// A repository's Secrets / Variables tabs list what its organization gives it (1.0, B7a; board
/// Place-Table): read-only muted rows with their reach, and "Overrides" on the repository's own
/// item of the same name.
@MainActor
@Suite("Inherited organization items")
struct RepoDetailInheritedTests {
    /// The imported Example-Org/example-repo (private) with Example-Org in the vault: NPM_TOKEN
    /// (all), STRIPE_KEY (selected, list unknown) and REGION (private, eu-west).
    @MainActor
    struct Fixture {
        let harness: TestHarness
        let repositoryID: RepoID
        let organization: OrganizationModel
        let recorder: ActionRecorder
        let model: RepoDetailViewModel

        /// The organization's own secret `name` (all repositories).
        func addOrganizationSecret(_ name: String) throws {
            _ = try harness.data.organizationItems.addItem(
                organizationID: organization.id,
                kind: .secret,
                name: name,
                value: SecretBytes(utf8: EditorFixtures.secretValue),
                access: .all
            )
        }
    }

    static func fixture() async throws -> Fixture {
        let (harness, id) = try await EditorFixtures.importedHarness()
        let owner = TestFixtures.owner
        harness.runner.stub(argumentsPrefix: ["secret", "list", "--org=\(owner)"], with: .success(OrganizationViewModelTests.secrets))
        harness.runner.stub(argumentsPrefix: ["variable", "list", "--org=\(owner)"], with: .success(OrganizationViewModelTests.variables))
        let organization = try await harness.data.organizations.importOrganization(login: owner, accountLogin: TestFixtures.account).organization
        let recorder = ActionRecorder()
        let model = RepoDetailViewModel(
            repositoryID: id,
            dependencies: harness.dependencies(recorder: recorder),
            repository: { harness.repository(id) },
            scopeSummary: { scope in try? harness.data.config.scopes(repositoryID: id).first { $0.scope == scope } }
        )
        model.kind = .secret
        return Fixture(harness: harness, repositoryID: id, organization: organization, recorder: recorder, model: model)
    }

    /// Plus an organization API_TOKEN (all) that the repository's own API_TOKEN overrides.
    @Test func theOrganizationsItemsAreReadOnlyRowsAndAnOwnItemOverridesOne() async throws {
        let fixture = try await Self.fixture()
        let (harness, id, model, recorder) = (fixture.harness, fixture.repositoryID, fixture.model, fixture.recorder)
        let owner = TestFixtures.owner
        try fixture.addOrganizationSecret("API_TOKEN")

        #expect(await TestFixtures.eventually { model.tableRows.map(\.name) == ["API_TOKEN", "NPM_TOKEN"] })
        let own = try #require(model.tableRows.first)
        #expect(own.inherited == nil)
        #expect(own.overrides == owner)
        let npm = try #require(model.tableRows.last)
        #expect(npm.inherited?.scope == "\(owner) · all repos")
        #expect(npm.overrides == nil)
        #expect(model.display(for: npm) == .masked, "an organization secret is on GitHub without a value here")
        #expect(model.rows.map(\.name) == ["API_TOKEN"], "actions only see the scope's own rows")

        // Read only: nothing to delete, copy or edit.
        model.selection = [npm.id]
        #expect(model.rows(for: model.selection).isEmpty)
        #expect(!model.canDeleteSelection)
        model.edit(npm)
        #expect(recorder.presented.isEmpty)

        model.kind = .variable
        #expect(await TestFixtures.eventually { model.tableRows.map(\.name) == ["BASE_URL", "REGION"] })
        let region = try #require(model.tableRows.last)
        #expect(region.inherited?.scope == "\(owner) · private and internal")
        #expect(await TestFixtures.eventually { model.display(for: region) == .plain("eu-west") })
        // Locking drops the organization's variables too.
        model.vaultDidLock()
        #expect(model.display(for: region) == .masked)

        // In production its own REGION overrides the organization's, and the repository level's
        // API_TOKEN keeps the organization's out.
        let scopes = try harness.data.config.scopes(repositoryID: id)
        model.select(scope: try #require(scopes.first { $0.environment?.name == "production" }).scope)
        // Until production's own items arrive, the organization's REGION is the only row (inherited).
        #expect(await TestFixtures.eventually {
            model.tableRows.map(\.name) == ["REGION"] && model.tableRows.first?.overrides == owner
        })
        #expect(model.tableRows.first?.inherited == nil)
        model.kind = .secret
        #expect(await TestFixtures.eventually { model.tableRows.map(\.name) == ["DEPLOY_KEY", "NPM_TOKEN"] })
    }

    /// Selected inherited rows have nothing to count, copy or delete: no selection bar, no ⌘C.
    @Test func selectingInheritedRowsOffersNoSelectionActions() async throws {
        let fixture = try await Self.fixture()
        let model = fixture.model
        try fixture.addOrganizationSecret("SENTRY_DSN")
        #expect(await TestFixtures.eventually { model.tableRows.map(\.name) == ["API_TOKEN", "NPM_TOKEN", "SENTRY_DSN"] })
        let inherited = model.tableRows.filter { $0.inherited != nil }.map(\.id)
        #expect(inherited.count == 2)

        model.selection = Set(inherited)
        #expect(!model.showsSelectionActions)
        #expect(!model.canCopySelection)

        // With one of the scope's own rows, ⌘C copies it; the bar still needs two of them.
        let own = try #require(model.tableRows.first)
        model.selection.insert(own.id)
        #expect(model.canCopySelection)
        #expect(!model.showsSelectionActions)
    }
}
