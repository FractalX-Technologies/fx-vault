import Foundation
import GitHubKit
import SyncEngine
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

/// Repository listing, add by name, import, refresh and removal (M2), with scripted gh output.
@Suite("RepoCatalogRepository")
struct RepoCatalogTests {
    // MARK: - Import

    @Test func importStoresEnvironmentsSecretsAndVariables() async throws {
        let harness = try await ConfigHarness.make()
        let provider = FakeSchedulerProvider()
        provider.scriptImport()
        let catalog = RepoCatalogRepository(session: harness.session, schedulers: provider, clock: harness.clock)

        let result = try await catalog.importRepository(try GHRepoRef(owner: "owner-a", name: "repo-a"), accountLogin: ConfigFixture.login)
        let repo = result.repository
        #expect(result.environmentCount == 2)
        #expect(result.secretCount == 2)
        #expect(result.variableCount == 2)
        #expect(result.unreadable.isEmpty)
        #expect(Set(result.skippedNames.map(\.name)) == ["..", "1FXV_FIXTURE_BAD"])
        #expect(repo.capability == .full)
        #expect(try AccountStore(database: harness.database).fetch(login: ConfigFixture.login) != nil)

        // Environments as GitHub has them, with patterns and foreign rules.
        let environments = try harness.store.fetchEnvironments(repositoryID: repo.id)
        #expect(environments.map(\.name) == ["production", "staging"])
        let production = try #require(environments.first)
        #expect(production.syncedName == "production")
        #expect(production.syncedBranchPolicy == .custom)
        #expect(production.githubEnvID == 101)
        #expect(production.foreignRulesJSON?.contains("required_reviewers") == true)
        #expect(production.branchPolicy.activePatterns.map(\.pattern) == ["release/*", "v*"])
        #expect(production.branchPolicy.activePatterns.allSatisfy { $0.isSynced })

        // Secrets are value-missing with GitHub's updatedAt; variables decrypt.
        let items = try harness.states(repo)
        let token = try #require(items.first { $0.name == "FXV_FIXTURE_API_TOKEN" })
        #expect(token.hasValue == false)
        #expect(token.syncedName == "FXV_FIXTURE_API_TOKEN")
        #expect(token.remoteUpdatedAt != nil)
        #expect(token.provenance == .github)
        let url = try #require(items.first { $0.name == "FXV_FIXTURE_URL" })
        #expect(try harness.reveal(url.id) == "https://example.invalid/api")
        #expect(url.valueFingerprint == url.syncedFingerprint)
        #expect(url.hasSyncedValue)
        // D32: a value from GitHub is stored as listed, trailing newline included.
        let pem = try #require(items.first { $0.name == "FXV_FIXTURE_PEM" })
        #expect(pem.scope == .environment(production.id))
        #expect(try harness.reveal(pem.id) == "-----BEGIN FXV FIXTURE-----\nAAAA\n-----END FXV FIXTURE-----\n")

        // An import leaves nothing pending.
        #expect(try harness.changeSet(repo).isEmpty)
        #expect(items.allSatisfy { $0.model.syncStatus == .synced })
    }

    @Test func adminRequiredLeavesTheScopeUnreadableAndReadOnly() async throws {
        let harness = try await ConfigHarness.make()
        let provider = FakeSchedulerProvider()
        provider.scriptImport(permission: "WRITE", repoSecretsFailure: GHFixtures.adminRequired)
        let catalog = RepoCatalogRepository(session: harness.session, schedulers: provider, clock: harness.clock)

        let result = try await catalog.importRepository(try GHRepoRef(owner: "owner-a", name: "repo-a"), accountLogin: ConfigFixture.login)
        #expect(result.unreadable == [ImportReadFailureModel(target: .secrets(environment: nil), error: .adminRequired)])
        #expect(result.repository.capability == .readOnly(.adminRequired))
        let environment = try #require(try harness.store.fetchEnvironments(repositoryID: result.repository.id).first)
        let edit = configError {
            _ = try harness.config.addItem(
                repositoryID: result.repository.id,
                scope: .environment(environment.id),
                kind: .secret,
                name: "NEW",
                value: SecretBytes(utf8: "v")
            )
        }
        #expect(edit == .readOnly(.adminRequired))
    }

    @Test func importNeedsAnUnlockedVaultAndRejectsDuplicates() async throws {
        let harness = try await ConfigHarness.make()
        let provider = FakeSchedulerProvider()
        provider.scriptImport()
        let catalog = RepoCatalogRepository(session: harness.session, schedulers: provider, clock: harness.clock)
        let ref = try GHRepoRef(owner: "owner-a", name: "repo-a")

        harness.manager.lock()
        #expect(await catalogError { try await catalog.importRepository(ref, accountLogin: ConfigFixture.login) } == .vault(.locked))
        #expect(try RepoStore(database: harness.database).fetchAll().isEmpty)

        try await harness.manager.unlock(password: ConfigFixture.password)
        provider.scriptImport()
        let imported = try await catalog.importRepository(ref, accountLogin: ConfigFixture.login)
        #expect(await catalogError { try await catalog.importRepository(ref, accountLogin: ConfigFixture.login) } == .alreadyImported(imported.repository.id))
    }

    @Test func variableValuesNeverReachTheDatabaseFile() async throws {
        let directory = try ConfigTempDirectory()
        defer { directory.remove() }
        let database = try DatabaseFactory.openOnDisk(directory: directory.url)
        let harness = try await ConfigHarness.make(database: database)
        let marker = "FXV_FIXTURE_SCAN_7c41e9d2b8"
        let provider = FakeSchedulerProvider()
        provider.scriptImport(repoVariables: [(name: "FXV_FIXTURE_SCANNED", value: marker)])
        let catalog = RepoCatalogRepository(session: harness.session, schedulers: provider, clock: harness.clock)

        let result = try await catalog.importRepository(try GHRepoRef(owner: "owner-a", name: "repo-a"), accountLogin: ConfigFixture.login)
        let item = try #require(try harness.states(result.repository).first { $0.name == "FXV_FIXTURE_SCANNED" })
        #expect(try harness.reveal(item.id) == marker)

        let files = try FileManager.default.contentsOfDirectory(at: directory.url, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(DatabaseFactory.databaseFileName) }
        #expect(!files.isEmpty)
        let bytes = try files.reduce(into: Data()) { $0.append(try Data(contentsOf: $1)) }
        #expect(bytes.range(of: Data(marker.utf8)) == nil)
        // The scan does read the files: the (plaintext) name is there.
        #expect(bytes.range(of: Data("FXV_FIXTURE_SCANNED".utf8)) != nil)
    }

    // MARK: - Catalog

    @Test func catalogGroupsByOwnerAndASamlOrgIsUnavailable() async throws {
        let harness = try await ConfigHarness.make()
        let provider = FakeSchedulerProvider()
        let runner = provider.runner
        let catalog = RepoCatalogRepository(session: harness.session, schedulers: provider, clock: harness.clock)
        let samlRepo = try seedRepository(harness, owner: "org-b", name: "locked-repo", ownerType: .organization)
        let listedRepo = try seedRepository(harness, owner: "org-a", name: "repo-x", ownerType: .organization, hasAdmin: false)

        runner.enqueue(.success("org-a\norg-b\nuser-a\n"), matching: { $0.starts(with: ["org", "list"]) })
        runner.enqueue(.success(GHFixtures.repoList(owner: "user-a", names: ["dotfiles"])), matching: GHArgv.isRepoList("user-a"))
        runner.enqueue(.success("[" + GHFixtures.repoJSON(owner: "org-a", name: "repo-x", nodeID: listedRepo.githubID) + "]"), matching: GHArgv.isRepoList("org-a"))
        runner.enqueue(.failure(stderr: GHFixtures.saml), matching: GHArgv.isRepoList("org-b"))

        let result = try await catalog.catalog(accountLogin: ConfigFixture.login)
        #expect(result.owners.map(\.login) == ["user-a", "org-a", "org-b"])
        #expect(result.owners.map(\.ownerType) == [.user, .organization, .organization])
        #expect(result.owners[0].repositories.map(\.ref.name) == ["dotfiles"])
        #expect(result.owners[0].repositories.first?.isImported == false)
        #expect(result.owners[0].isUnavailable == false)

        let orgA = result.owners[1]
        #expect(orgA.isUnavailable == false)
        #expect(orgA.repositories.first?.importedRepoID == listedRepo.id)
        #expect(orgA.repositories.first?.capability() == .full)

        let orgB = result.owners[2]
        guard case .samlRequired = orgB.failure else {
            Issue.record("Expected a SAML failure, got \(String(describing: orgB.failure))")
            return
        }
        #expect(orgB.repositories.map(\.source) == [.vaultOnly])
        #expect(orgB.repositories.first?.isUnavailable == true)

        // Only the SAML org's vault row is marked unavailable; the listed one is refreshed.
        let repos = RepoStore(database: harness.database)
        #expect(try repos.fetch(id: samlRepo.id)?.isUnavailable == true)
        let refreshed = try #require(try repos.fetch(id: listedRepo.id))
        #expect(refreshed.isUnavailable == false)
        #expect(refreshed.hasAdmin)
    }

    @Test func addByName() async throws {
        let harness = try await ConfigHarness.make()
        let provider = FakeSchedulerProvider()
        let runner = provider.runner
        let catalog = RepoCatalogRepository(session: harness.session, schedulers: provider, clock: harness.clock)

        runner.enqueue(.success(GHFixtures.repoJSON(owner: "owner-x", name: "shared", permission: "WRITE")), matching: GHArgv.isRepoView("owner-x/shared"))
        let added = try await catalog.lookUpRepository(fullName: " owner-x/shared ", accountLogin: ConfigFixture.login)
        #expect(added.source == .addedByName)
        #expect(added.capability() == .readOnly(.adminRequired))
        #expect(added.capability(writePolicy: .repoLevelOnly) == .repoLevelOnly)

        runner.enqueue(.failure(stderr: GHFixtures.notFound), matching: GHArgv.isRepoView("owner-z/repo-z"))
        #expect(await catalogError { _ = try await catalog.lookUpRepository(fullName: "owner-z/repo-z", accountLogin: ConfigFixture.login) } == .github(.notFound))
        for invalid in ["no-slash", "owner/../x", "-owner/name", "owner/na me"] {
            let error = await catalogError { _ = try await catalog.lookUpRepository(fullName: invalid, accountLogin: ConfigFixture.login) }
            guard case .github(.invalidInput) = error else {
                Issue.record("Expected invalid input for \(invalid), got \(String(describing: error))")
                continue
            }
        }

        // The added repository shows under its own owner in the next listing.
        runner.enqueue(.success(""), matching: { $0.starts(with: ["org", "list"]) })
        runner.enqueue(.success("[]"), matching: GHArgv.isRepoList("user-a"))
        let listing = try await catalog.catalog(accountLogin: ConfigFixture.login)
        #expect(listing.owners.map(\.login) == ["user-a", "owner-x"])
        #expect(listing.owners[1].repositories.map(\.ref.fullName) == ["owner-x/shared"])
    }

    @Test func refreshAndRemove() async throws {
        let harness = try await ConfigHarness.make()
        let provider = FakeSchedulerProvider()
        let runner = provider.runner
        let catalog = RepoCatalogRepository(session: harness.session, schedulers: provider, clock: harness.clock)
        let repo = try seedRepository(harness, owner: "owner-a", name: "repo-a", ownerType: .user)
        let item = try harness.add(repo, "TOKEN", value: ConfigFixture.valueA)

        runner.enqueue(.success(GHFixtures.repoJSON(owner: "owner-a", name: "repo-a", permission: "READ", isArchived: true)), matching: GHArgv.isRepoView("owner-a/repo-a"))
        let refreshed = try await catalog.refreshRepository(repo.id)
        #expect(refreshed.capability == .readOnly(.archived))
        #expect(refreshed.lastRefreshedAt == harness.clock.now)

        runner.enqueue(.failure(stderr: GHFixtures.saml), matching: GHArgv.isRepoView("owner-a/repo-a"))
        #expect(try await catalog.refreshRepository(repo.id).isUnavailable)

        try await catalog.removeFromVault(repo.id)
        #expect(try RepoStore(database: harness.database).fetch(id: repo.id) == nil)
        #expect(try harness.store.fetchItemRecord(id: item) == nil)
        #expect(await catalogError { try await catalog.removeFromVault(repo.id) } == .repositoryNotFound)
    }

    // MARK: - Helpers

    private func seedRepository(
        _ harness: ConfigHarness,
        owner: String,
        name: String,
        ownerType: OwnerType,
        hasAdmin: Bool = true
    ) throws -> RepoModel {
        if try AccountStore(database: harness.database).fetch(login: ConfigFixture.login) == nil {
            try AccountStore(database: harness.database).save(AccountModel(login: ConfigFixture.login, lastSeenAt: harness.clock.now))
        }
        let repo = RepoModel(
            accountLogin: ConfigFixture.login,
            githubID: "R_\(owner)_\(name)",
            ownerLogin: owner,
            ownerType: ownerType,
            name: name,
            visibility: .private,
            hasAdmin: hasAdmin,
            hasPush: hasAdmin,
            origin: .imported,
            importedAt: harness.clock.now
        )
        try RepoStore(database: harness.database).insert(repo)
        return repo
    }
}
