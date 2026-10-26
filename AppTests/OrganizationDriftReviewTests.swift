import Foundation
import SyncEngine
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// An organization's Refresh (1.0, B7b): the rows GitHub changed are marked, and the review
/// resolves each finding with the repository drift review's rows and copy.
@MainActor
@Suite("Organization Refresh")
struct OrganizationDriftReviewTests {
    // gitleaks:allow (secret names only, no values)
    /// GitHub now: NPM_TOKEN changed, DEPLOY_KEY added, STRIPE_KEY as imported, REGION deleted.
    static let secrets = """
    [{"name":"STRIPE_KEY","numSelectedRepos":3,"updatedAt":"2026-10-12T10:00:00Z","visibility":"selected"},
     {"name":"NPM_TOKEN","numSelectedRepos":0,"updatedAt":"2026-10-20T10:00:00Z","visibility":"all"},
     {"name":"DEPLOY_KEY","numSelectedRepos":0,"updatedAt":"2026-10-25T10:00:00Z","visibility":"private"}]
    """

    @Test func refreshMarksWhatChangedOnGitHubAndTheReviewResolvesIt() async throws {
        let (harness, organization) = try await OrganizationEditingTests().imported()
        let recorder = ActionRecorder()
        let dependencies = harness.dependencies(recorder: recorder)
        let detail = OrganizationDetailViewModel(
            organizationID: organization.id,
            dependencies: dependencies,
            organization: { organization },
            repositoryNames: { [] }
        )
        #expect(await TestFixtures.eventually { detail.items.count == 3 })
        harness.runner.replaceStub(argumentsPrefix: ["secret", "list", "--org=Example-Org"], with: .success(Self.secrets))
        harness.runner.replaceStub(argumentsPrefix: ["variable", "list", "--org=Example-Org"], with: .success("[]"))

        detail.refreshNow()

        #expect(await TestFixtures.eventually { detail.refresh != nil && !detail.isRefreshing })
        #expect(detail.findings.map(\.name) == ["DEPLOY_KEY", "NPM_TOKEN", "REGION"])
        let npm = try #require(detail.rows.first { $0.name == "NPM_TOKEN" })
        let stripe = try #require(detail.rows.first { $0.name == "STRIPE_KEY" })
        #expect(detail.isChangedOnGitHub(npm))
        #expect(!detail.isChangedOnGitHub(stripe))

        detail.reviewChanges()
        let context = OrgDriftContext(organizationID: organization.id, findings: detail.findings)
        #expect(recorder.presented == [.orgDrift(context)])

        var resolved: Set<String> = []
        let review = OrgDriftViewModel(context: context, dependencies: dependencies) { ids in
            resolved.formUnion(ids)
            detail.didResolve(ids)
        }
        await review.load()
        #expect(review.login == "Example-Org")
        let rows = review.rows
        #expect(rows.map(\.scope) == Array(repeating: PlaceCopy.organization, count: 3))
        #expect(rows[0].title.hasPrefix("Secret DEPLOY_KEY was added on GitHub"))
        #expect(rows[1].title.hasPrefix("Secret NPM_TOKEN was changed on GitHub"))
        #expect(rows[2].title == "Variable REGION was deleted on GitHub")
        // A secret GitHub changed: no value to keep, and taking GitHub's leaves it without one.
        #expect(rows[1].keepLocal.unavailableReason == DriftCopy.unavailable(.valueMissing))
        #expect(rows[1].acceptGitHub.explanation == OrganizationCopy.acceptSecretChange)
        #expect(rows[0].keepLocal.explanation == DriftCopy.keepLocalExplanation(.remoteAdded))
        #expect(rows[2].acceptGitHub.needsConfirmation)

        await review.choose(rows[1].id, .acceptGitHub)
        #expect(review.findings.map(\.name) == ["DEPLOY_KEY", "REGION"])
        #expect(review.notice == DriftCopy.resolved)
        #expect(!detail.isChangedOnGitHub(npm))

        // Taking GitHub's deletion asks first.
        await review.choose(rows[2].id, .acceptGitHub)
        #expect(review.confirmation?.title == DriftCopy.deleteItemTitle("REGION"))
        await review.confirm()
        #expect(await TestFixtures.eventually { !detail.items.contains { $0.name == "REGION" } })

        // Keeping the vault's side of an item only GitHub has deletes it there on the next Sync.
        await review.choose(rows[0].id, .keepLocal)
        #expect(review.findings.isEmpty)
        #expect(await TestFixtures.eventually { detail.items.first { $0.name == "DEPLOY_KEY" }?.syncStatus == .deleted })
        #expect(detail.findings.isEmpty)
        #expect(resolved.count == 3)
    }
}
