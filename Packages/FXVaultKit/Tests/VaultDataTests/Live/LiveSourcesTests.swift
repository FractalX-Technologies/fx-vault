import DestinationKit
import Foundation
import GitHubKit
import Testing
import VaultCore
@testable import VaultData

/// Read-only checks of the 1.0 sources against the real gh and az. Never enabled in CI.
/// `FXV_LIVE_ORG=<org>` (one the active account administers) and `FXV_LIVE_AZ=1`; nothing is
/// written to GitHub or Azure, and no assertion message holds a name or a value.
@Suite("Live 1.0 sources (read-only, opt-in)", .serialized, .timeLimit(.minutes(5)))
struct LiveSourcesTests {
    static let environment = ProcessInfo.processInfo.environment

    // MARK: - Organization (B12–B15)

    @Test(.enabled(if: environment["FXV_LIVE_ORG"] != nil))
    func anOrganizationImportsThenRefreshesWithNoDifferences() async throws {
        let login = try #require(Self.environment["FXV_LIVE_ORG"])
        let world = try await E2EWorld.live()
        defer { world.remove() }
        let organizations = OrganizationRepository(
            session: world.session,
            schedulers: world.schedulers,
            clock: world.clock,
            deletions: OrgDeletionLog()
        )

        let imported = try await organizations.importOrganization(login: login, accountLogin: world.accountLogin)
        #expect(imported.skippedNames.isEmpty, "skipped: \(imported.skippedNames.count)")
        // Right after the import nothing has moved: a finding means a decoding or comparison bug.
        let refresh = try await organizations.refresh(organizationID: imported.organization.id)
        #expect(refresh.findings.isEmpty, "findings: \(refresh.findings.count)")
    }

    @Test(.enabled(if: environment["FXV_LIVE_ORG"] != nil))
    func selectedItemsListTheirRepositories() async throws {
        let login = try #require(Self.environment["FXV_LIVE_ORG"])
        let world = try await E2EWorld.live()
        defer { world.remove() }
        let github = try #require(world.github)
        let scheduler = try await github.scheduler(for: world.accountLogin)

        for secret in try await scheduler.listOrganizationSecrets(login) where secret.visibility == .selected {
            let repositories = try await scheduler.organizationSecretRepositories(secret.name, organization: login)
            #expect(repositories.count == secret.numSelectedRepos)
            #expect(repositories.allSatisfy { !$0.isEmpty && !$0.contains("/") })
        }
        let variables = try await scheduler.listOrganizationVariables(login)
        defer { variables.forEach { $0.wipe() } }
        for variable in variables where variable.visibility == .selected {
            let repositories = try await scheduler.organizationVariableRepositories(variable.name, organization: login)
            #expect(repositories.count == variable.numSelectedRepos)
        }
    }

    // MARK: - Azure (B8a)

    @Test(.enabled(if: environment["FXV_LIVE_AZ"] == "1"))
    func everySubscriptionAndItsVaultsDecode() async throws {
        let world = try await E2EWorld.live()
        defer { world.remove() }
        let github = try #require(world.github)
        let caches = world.directory.directory("az")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let discovery = AzureDiscoveryRepository(
            github: github,
            runner: ProcessRunner(),
            identity: ProcessIdentityModel.current(processEnvironment: LiveE2E.finderEnvironment),
            workingDirectory: try EmptyWorkingDirectory.prepare(in: caches)
        )

        let listed = try await discovery.discover()
        #expect(!listed.isEmpty)
        for entry in listed {
            if case .failure(let error) = entry.vaults {
                Issue.record("a subscription's vaults did not decode: \(error.logCode)")
            }
        }
    }
}
