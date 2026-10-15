import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// The multi-select share scope tree (v0.2.0): tri-state propagation and the selection built
/// for every combination (repository level only, environments, both, single items, partial
/// environments), plus the branch-policy rule.
@MainActor
@Suite("Share scope tree")
struct SharingScopeTreeModelTests {
    /// `owner-a/api`: repository level `API_KEY` (secret) and `REGION` (variable); `production`
    /// with `DB_PASSWORD` and `LOG_LEVEL`; `staging` with `TOKEN`; `empty` without items.
    @MainActor
    struct Fixture {
        static let date = Date(timeIntervalSince1970: 1_790_000_000)

        let repository: RepoModel
        let production: EnvironmentModel
        let staging: EnvironmentModel
        let empty: EnvironmentModel
        let apiKey: ConfigItemModel
        let region: ConfigItemModel
        let dbPassword: ConfigItemModel
        let logLevel: ConfigItemModel
        let token: ConfigItemModel
        let deleted: ConfigItemModel

        init() {
            repository = RepoModel(
                accountLogin: "user-a",
                githubID: "R_test",
                ownerLogin: "owner-a",
                ownerType: .user,
                name: "api",
                visibility: .private,
                origin: .imported,
                importedAt: Self.date
            )
            production = Self.environment("production", repository.id, order: 0)
            staging = Self.environment("staging", repository.id, order: 1)
            empty = Self.environment("empty", repository.id, order: 2)
            apiKey = Self.item("API_KEY", .secret, .repository, repository.id)
            region = Self.item("REGION", .variable, .repository, repository.id)
            dbPassword = Self.item("DB_PASSWORD", .secret, .environment(production.id), repository.id)
            logLevel = Self.item("LOG_LEVEL", .variable, .environment(production.id), repository.id)
            token = Self.item("TOKEN", .secret, .environment(staging.id), repository.id)
            deleted = Self.item("GONE", .secret, .repository, repository.id, isDeleted: true)
        }

        static func environment(_ name: String, _ repositoryID: RepoID, order: Int) -> EnvironmentModel {
            EnvironmentModel(repositoryID: repositoryID, name: name, sortOrder: order, createdAt: date, updatedAt: date)
        }

        static func item(
            _ name: String,
            _ kind: ConfigKind,
            _ scope: ConfigScope,
            _ repositoryID: RepoID,
            isDeleted: Bool = false
        ) -> ConfigItemModel {
            ConfigItemModel(
                repositoryID: repositoryID,
                scope: scope,
                kind: kind,
                name: name,
                valueState: .present,
                isDeleted: isDeleted,
                syncStatus: .synced,
                createdAt: date,
                updatedAt: date
            )
        }

        func tree(_ selection: ShareSelectionModel? = nil) -> ShareScopeTreeModel {
            let scopes = [nil, production, staging, empty].map { environment in
                ConfigScopeSummaryModel(
                    scope: ConfigScope(environmentID: environment?.id),
                    environment: environment,
                    itemCount: 0,
                    valueMissingCount: 0,
                    hasPendingChanges: false
                )
            }
            let items: [ConfigScope: [ConfigItemModel]] = [
                .repository: [region, apiKey, deleted],
                .environment(production.id): [logLevel, dbPassword],
                .environment(staging.id): [token],
            ]
            return ShareScopeTreeModel.build(repository: repository, scopes: scopes, items: items, selection: selection)
        }

        func subset(environments: Set<EnvironmentID> = [], items: Set<ConfigItemID> = []) -> ShareSelectionModel {
            .subset(ShareSubsetModel(repositoryID: repository.id, environmentIDs: environments, itemIDs: items))
        }
    }

    private func node(_ id: ShareScopeNodeID, in tree: ShareScopeTreeModel) throws -> ShareScopeNodeModel {
        func find(_ node: ShareScopeNodeModel) -> ShareScopeNodeModel? {
            if node.id == id { return node }
            return (node.children ?? []).lazy.compactMap(find).first
        }
        return try #require(find(tree.root))
    }

    // MARK: - Structure

    @Test func theTreeHasARepositoryLevelGroupThenEnvironments() throws {
        let fixture = Fixture()
        let tree = fixture.tree()
        #expect(tree.root.title == "owner-a/api")
        #expect(tree.root.children?.map(\.title) == ["Repository level", "production", "staging", "empty"])
        let group = try node(.repositoryLevel(fixture.repository.id), in: tree)
        // Secrets first, then variables; deleted items are never offered.
        #expect(group.children?.map(\.title) == ["API_KEY", "REGION"])
        #expect(try node(.environment(fixture.production.id), in: tree).children?.map(\.title) == ["DB_PASSWORD", "LOG_LEVEL"])
        // An environment without items is a leaf (no disclosure triangle).
        #expect(try node(.environment(fixture.empty.id), in: tree).children == nil)
        #expect(tree.selection == nil)
        #expect(tree.state(of: tree.root) == .unchecked)
    }

    @Test func noRepositoryLevelGroupWithoutRepositoryItems() {
        let fixture = Fixture()
        let tree = ShareScopeTreeModel.build(
            repository: fixture.repository,
            scopes: [ConfigScopeSummaryModel(scope: .environment(fixture.staging.id), environment: fixture.staging, itemCount: 1, valueMissingCount: 0, hasPendingChanges: false)],
            items: [.environment(fixture.staging.id): [fixture.token]],
            selection: .repository(fixture.repository.id)
        )
        #expect(tree.root.children?.map(\.title) == ["staging"])
        #expect(tree.state(of: tree.root) == .checked)
    }

    // MARK: - Tri-state propagation

    @Test func checkingAParentChecksEverythingUnderIt() throws {
        let fixture = Fixture()
        var tree = fixture.tree()
        tree.setChecked(true, for: tree.root)
        #expect(tree.state(of: tree.root) == .checked)
        for id: ShareScopeNodeID in [.repositoryLevel(fixture.repository.id), .environment(fixture.production.id), .environment(fixture.empty.id), .item(fixture.token.id)] {
            #expect(tree.state(of: id) == .checked)
        }
        #expect(tree.selection == .repository(fixture.repository.id))

        tree.setChecked(false, for: try node(.environment(fixture.production.id), in: tree))
        #expect(tree.state(of: .environment(fixture.production.id)) == .unchecked)
        #expect(tree.state(of: .item(fixture.dbPassword.id)) == .unchecked)
        #expect(tree.state(of: tree.root) == .mixed)
    }

    @Test func checkingEveryChildChecksTheParent() throws {
        let fixture = Fixture()
        var tree = fixture.tree()
        tree.setChecked(true, for: try node(.item(fixture.dbPassword.id), in: tree))
        #expect(tree.state(of: .environment(fixture.production.id)) == .mixed)
        #expect(tree.state(of: tree.root) == .mixed)
        tree.setChecked(true, for: try node(.item(fixture.logLevel.id), in: tree))
        #expect(tree.state(of: .environment(fixture.production.id)) == .checked)
        // Every item checked = the environment is selected: its policy travels.
        #expect(tree.selection == .environment(fixture.production.id))
    }

    @Test func toggleChecksAMixedRowAndUnchecksACheckedOne() throws {
        let fixture = Fixture()
        var tree = fixture.tree(.item(fixture.dbPassword.id))
        let production = try node(.environment(fixture.production.id), in: tree)
        #expect(tree.state(of: production) == .mixed)
        tree.toggle(production)
        #expect(tree.state(of: production) == .checked)
        tree.toggle(production)
        #expect(tree.state(of: production) == .unchecked)
        #expect(tree.isEmpty)
        #expect(tree.selection == nil)
    }

    @Test func theRootOfAnEmptyRepositoryCannotBeChecked() {
        let fixture = Fixture()
        var tree = ShareScopeTreeModel.build(repository: fixture.repository, scopes: [], items: [:], selection: nil)
        tree.setChecked(true, for: tree.root)
        #expect(tree.state(of: tree.root) == .unchecked)
        #expect(tree.selection == nil)
    }

    // MARK: - Every combination

    @Test func repositoryLevelOnly() throws {
        let fixture = Fixture()
        var tree = fixture.tree()
        tree.setChecked(true, for: try node(.repositoryLevel(fixture.repository.id), in: tree))
        #expect(tree.state(of: .repositoryLevel(fixture.repository.id)) == .checked)
        #expect(tree.state(of: tree.root) == .mixed)
        #expect(tree.selection == fixture.subset(items: [fixture.apiKey.id, fixture.region.id]))
    }

    @Test func oneEnvironment() throws {
        let fixture = Fixture()
        var tree = fixture.tree()
        tree.setChecked(true, for: try node(.environment(fixture.staging.id), in: tree))
        #expect(tree.selection == .environment(fixture.staging.id))
    }

    @Test func severalEnvironments() throws {
        let fixture = Fixture()
        var tree = fixture.tree()
        tree.setChecked(true, for: try node(.environment(fixture.production.id), in: tree))
        tree.setChecked(true, for: try node(.environment(fixture.empty.id), in: tree))
        #expect(tree.selection == fixture.subset(environments: [fixture.production.id, fixture.empty.id]))
    }

    @Test func repositoryLevelPlusEnvironments() throws {
        let fixture = Fixture()
        var tree = fixture.tree()
        tree.setChecked(true, for: try node(.repositoryLevel(fixture.repository.id), in: tree))
        tree.setChecked(true, for: try node(.environment(fixture.staging.id), in: tree))
        #expect(tree.selection == fixture.subset(
            environments: [fixture.staging.id],
            items: [fixture.apiKey.id, fixture.region.id]
        ))
    }

    @Test func individualItems() throws {
        let fixture = Fixture()
        var tree = fixture.tree()
        tree.setChecked(true, for: try node(.item(fixture.region.id), in: tree))
        #expect(tree.selection == .item(fixture.region.id))
        tree.setChecked(true, for: try node(.item(fixture.dbPassword.id), in: tree))
        // production is mixed: DB_PASSWORD travels in a partial environment without its policy.
        #expect(tree.state(of: .environment(fixture.production.id)) == .mixed)
        #expect(tree.selection == fixture.subset(items: [fixture.region.id, fixture.dbPassword.id]))
    }

    @Test func partialEnvironmentPlusWholeEnvironment() throws {
        let fixture = Fixture()
        var tree = fixture.tree()
        tree.setChecked(true, for: try node(.item(fixture.logLevel.id), in: tree))
        tree.setChecked(true, for: try node(.environment(fixture.staging.id), in: tree))
        #expect(tree.selection == fixture.subset(environments: [fixture.staging.id], items: [fixture.logLevel.id]))
    }

    @Test func aSingleItemThatIsTheWholeEnvironmentSelectsTheEnvironment() throws {
        let fixture = Fixture()
        var tree = fixture.tree()
        tree.setChecked(true, for: try node(.item(fixture.token.id), in: tree))
        #expect(tree.state(of: .environment(fixture.staging.id)) == .checked)
        #expect(tree.selection == .environment(fixture.staging.id))
    }

    @Test func sharingTheOnlyItemOfAnEnvironmentFromItsMenuStaysAnItemShare() throws {
        let fixture = Fixture()
        // "Share this secret…" on TOKEN, staging's only item: no branch policy, no future items.
        var tree = fixture.tree(.item(fixture.token.id))
        #expect(tree.state(of: .environment(fixture.staging.id)) == .checked)
        #expect(tree.selection == .item(fixture.token.id))
        // Any change to the checks applies the usual rule again.
        let item = try node(.item(fixture.token.id), in: tree)
        tree.setChecked(false, for: item)
        tree.setChecked(true, for: item)
        #expect(tree.selection == .environment(fixture.staging.id))
    }

    @Test func everythingIsTheRepositorySelection() throws {
        let fixture = Fixture()
        var tree = fixture.tree()
        for id: ShareScopeNodeID in [.repositoryLevel(fixture.repository.id), .environment(fixture.production.id), .environment(fixture.staging.id), .environment(fixture.empty.id)] {
            tree.setChecked(true, for: try node(id, in: tree))
        }
        #expect(tree.state(of: tree.root) == .checked)
        #expect(tree.selection == .repository(fixture.repository.id))
    }

    // MARK: - Initial selection

    @Test func everySelectionRoundTripsThroughTheTree() {
        let fixture = Fixture()
        let selections: [ShareSelectionModel] = [
            .repository(fixture.repository.id),
            .environment(fixture.production.id),
            .environment(fixture.empty.id),
            .item(fixture.apiKey.id),
            fixture.subset(items: [fixture.apiKey.id, fixture.region.id]),
            fixture.subset(environments: [fixture.production.id, fixture.staging.id]),
            fixture.subset(environments: [fixture.staging.id], items: [fixture.apiKey.id, fixture.dbPassword.id]),
        ]
        for selection in selections {
            #expect(fixture.tree(selection).selection == selection)
        }
    }

    @Test func unknownIdsAreIgnored() {
        let fixture = Fixture()
        #expect(fixture.tree(.item(ConfigItemID())).selection == nil)
        #expect(fixture.tree(.item(fixture.deleted.id)).selection == nil)
        #expect(fixture.tree(.repository(RepoID())).selection == nil)
        #expect(fixture.tree(.subset(ShareSubsetModel(repositoryID: RepoID(), itemIDs: [fixture.apiKey.id]))).selection == nil)
        #expect(fixture.tree(fixture.subset(items: [ConfigItemID(), fixture.token.id])).selection == .environment(fixture.staging.id))
    }
}
