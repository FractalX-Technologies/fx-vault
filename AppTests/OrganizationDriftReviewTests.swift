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
    /// GitHub now: NPM_TOKEN changed, STRIPE_KEY reaches 4 repositories under the same date,
    /// DEPLOY_KEY added, API_TOKEN added there and here, REGION deleted, one name FX Vault
    /// can't hold.
    static let secrets = """
    [{"name":"STRIPE_KEY","numSelectedRepos":4,"updatedAt":"2026-10-12T10:00:00Z","visibility":"selected"},
     {"name":"NPM_TOKEN","numSelectedRepos":0,"updatedAt":"2026-10-20T10:00:00Z","visibility":"all"},
     {"name":"DEPLOY_KEY","numSelectedRepos":0,"updatedAt":"2026-10-25T10:00:00Z","visibility":"private"},
     {"name":"API_TOKEN","numSelectedRepos":0,"updatedAt":"2026-10-25T10:00:00Z","visibility":"all"},
     {"name":"1FXV_FIXTURE_BAD","numSelectedRepos":0,"updatedAt":"2026-10-25T10:00:00Z","visibility":"all"}]
    """

    @Test func refreshMarksWhatChangedOnGitHubAndTheReviewResolvesIt() async throws {
        let (harness, organization) = try await OrganizationEditingTests().imported()
        _ = try harness.data.organizationItems.addItem(
            organizationID: organization.id,
            kind: .secret,
            name: "API_TOKEN",
            value: SecretBytes(utf8: EditorFixtures.secretValue),
            access: .all
        )
        let recorder = ActionRecorder()
        let dependencies = harness.dependencies(recorder: recorder)
        let detail = OrganizationDetailViewModel(
            organizationID: organization.id,
            dependencies: dependencies,
            organization: { organization },
            repositoryNames: { [] }
        )
        #expect(await TestFixtures.eventually { detail.items.count == 4 })
        harness.runner.replaceStub(argumentsPrefix: ["secret", "list", "--org=Example-Org"], with: .success(Self.secrets))
        harness.runner.replaceStub(argumentsPrefix: ["variable", "list", "--org=Example-Org"], with: .success("[]"))

        detail.refreshNow()

        #expect(await TestFixtures.eventually { detail.refresh != nil && !detail.isRefreshing })
        #expect(detail.findings.map(\.name) == ["API_TOKEN", "DEPLOY_KEY", "NPM_TOKEN", "REGION", "STRIPE_KEY"])
        #expect(detail.skippedNote == nil, "the review lists the skipped names")
        let npm = try #require(detail.rows.first { $0.name == "NPM_TOKEN" })
        #expect(detail.isChangedOnGitHub(npm))

        detail.reviewChanges()
        let context = OrgDriftContext(organizationID: organization.id, findings: detail.findings, skippedNames: ["1FXV_FIXTURE_BAD"])
        #expect(recorder.presented == [.orgDrift(context)])

        var resolved: Set<String> = []
        let review = OrgDriftViewModel(context: context, dependencies: dependencies) { ids in
            resolved.formUnion(ids)
            detail.didResolve(ids)
        }
        await review.load()
        #expect(review.login == "Example-Org")
        #expect(review.notes == [DriftCopy.skipped(["1FXV_FIXTURE_BAD"])])
        let rows = Dictionary(uniqueKeysWithValues: zip(review.findings.map(\.name), review.rows))
        #expect(review.rows.allSatisfy { $0.scope == PlaceCopy.organization })
        let deploy = try #require(rows["DEPLOY_KEY"])
        let changed = try #require(rows["NPM_TOKEN"])
        let stripe = try #require(rows["STRIPE_KEY"])
        let region = try #require(rows["REGION"])
        let both = try #require(rows["API_TOKEN"])
        #expect(deploy.title.hasPrefix("Secret DEPLOY_KEY was added on GitHub"))
        #expect(changed.title.hasPrefix("Secret NPM_TOKEN was changed on GitHub"))
        #expect(region.title == "Variable REGION was deleted on GitHub")
        // A secret whose date moved: no value to keep, and taking GitHub's leaves it without one;
        // under the same date only its access changes.
        #expect(changed.keepLocal.unavailableReason == DriftCopy.unavailable(.valueMissing))
        #expect(changed.acceptGitHub.explanation == OrganizationCopy.acceptSecretChange)
        #expect(stripe.acceptGitHub.explanation == OrganizationCopy.acceptAccessChange)
        #expect(deploy.keepLocal.explanation == DriftCopy.keepLocalExplanation(.remoteAdded))
        // Added on both sides: Keep Local sends the vault's; Accept replaces it and asks first.
        #expect(both.isConflict)
        #expect(both.keepLocal.explanation == DriftCopy.bothAddedKeepLocal)
        #expect(both.acceptGitHub.explanation == DriftCopy.bothAddedAcceptGitHub(.secret, fillsValue: false))
        #expect(both.acceptGitHub.needsConfirmation)
        #expect(region.acceptGitHub.needsConfirmation)
        #expect(!deploy.acceptGitHub.needsConfirmation)

        await review.choose(changed.id, .acceptGitHub)
        #expect(!review.findings.contains { $0.name == "NPM_TOKEN" })
        #expect(review.notice == DriftCopy.resolved)
        #expect(!detail.isChangedOnGitHub(npm))

        // Taking GitHub's deletion asks first.
        await review.choose(region.id, .acceptGitHub)
        #expect(review.confirmation?.title == DriftCopy.deleteItemTitle("REGION"))
        #expect(review.confirmation?.confirmTitle == DriftCopy.confirmDelete)
        let confirmation = try #require(review.confirmation)
        review.cancelConfirmation() // the dialog dismisses before its button's task runs
        await review.confirm(confirmation)
        #expect(await TestFixtures.eventually { !detail.items.contains { $0.name == "REGION" } })

        // Taking GitHub's API_TOKEN over the one added here asks first too; cancelling keeps it.
        await review.choose(both.id, .acceptGitHub)
        #expect(review.confirmation == .replace(driftID: both.id, name: "API_TOKEN", isRenamed: false))
        #expect(review.confirmation?.confirmTitle == "Use GitHub's")
        review.cancelConfirmation()
        #expect(review.findings.contains { $0.name == "API_TOKEN" })

        // Keeping the vault's side of an item only GitHub has deletes it there on the next Sync.
        await review.choose(deploy.id, .keepLocal)
        #expect(await TestFixtures.eventually { detail.items.first { $0.name == "DEPLOY_KEY" }?.syncStatus == .deleted })
        #expect(review.findings.map(\.name) == ["API_TOKEN", "STRIPE_KEY"])
        #expect(detail.findings.map(\.name) == ["API_TOKEN", "STRIPE_KEY"])
        #expect(resolved.count == 3)
    }

    // gitleaks:allow (secret names only, no values)
    /// The imported listing again, plus one name FX Vault can't hold.
    static let unchangedSecrets = """
    [{"name":"STRIPE_KEY","numSelectedRepos":3,"updatedAt":"2026-10-12T10:00:00Z","visibility":"selected"},
     {"name":"NPM_TOKEN","numSelectedRepos":0,"updatedAt":"2026-08-02T10:00:00Z","visibility":"all"},
     {"name":"1FXV_FIXTURE_BAD","numSelectedRepos":0,"updatedAt":"2026-10-25T10:00:00Z","visibility":"all"}]
    """

    /// Nothing to review: the status line says which names were not compared.
    @Test func aRefreshWithNothingChangedNamesWhatItCouldNotCompare() async throws {
        let (harness, organization) = try await OrganizationEditingTests().imported()
        let detail = OrganizationDetailViewModel(
            organizationID: organization.id,
            dependencies: harness.dependencies(recorder: ActionRecorder()),
            organization: { organization },
            repositoryNames: { [] }
        )
        #expect(await TestFixtures.eventually { detail.items.count == 3 })
        harness.runner.replaceStub(argumentsPrefix: ["secret", "list", "--org=Example-Org"], with: .success(Self.unchangedSecrets))
        harness.runner.replaceStub(argumentsPrefix: ["variable", "list", "--org=Example-Org"], with: .success(OrganizationViewModelTests.variables))

        detail.refreshNow()

        #expect(await TestFixtures.eventually { detail.refresh != nil && !detail.isRefreshing })
        #expect(detail.findings.isEmpty)
        #expect(detail.skippedNote == DriftCopy.skipped(["1FXV_FIXTURE_BAD"]))
    }
}
