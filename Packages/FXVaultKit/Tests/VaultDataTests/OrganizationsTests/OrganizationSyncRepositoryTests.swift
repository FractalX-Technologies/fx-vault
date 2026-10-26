import Foundation
import GitHubKit
import Testing
import VaultCore
@testable import VaultData

/// Organization Sync (1.0, tasks/todo.md B6b) over scripted gh: the review's blocks, the
/// complete access every write sends, deletions, and the confirming listing.
@Suite("OrganizationSyncRepository")
struct OrganizationSyncRepositoryTests {
    struct Fixture {
        let base: OrganizationItemRepositoryTests.Fixture
        let sync: OrganizationSyncRepository

        static func make() async throws -> Fixture {
            let base = try await OrganizationItemRepositoryTests.Fixture.make()
            let harness = base.base.harness
            return Fixture(base: base, sync: OrganizationSyncRepository(
                session: harness.session,
                schedulers: base.base.provider,
                clock: harness.clock,
                deletions: base.base.deletions
            ))
        }

        var runner: FakeCommandRunner { base.base.provider.runner }
        var items: OrganizationItemRepository { base.items }
        var organizationID: OrganizationID { base.organization.id }

        /// B14/B15 for `name`: GitHub's list of repositories.
        func scriptRepositories(of name: String, _ names: [String]) {
            let repositories = names.map { #"{"name":"\#($0)"}"# }.joined(separator: ",")
            runner.enqueue(
                .success(#"[{"total_count":\#(names.count),"repositories":[\#(repositories)]}]"#),
                matching: { $0.first == "api" && $0.last?.contains("/\(name)/repositories") == true }
            )
        }

        func scriptWritesSucceed() {
            for prefix in [["secret", "set"], ["variable", "set"], ["secret", "delete"], ["variable", "delete"]] {
                runner.stub(argumentsPrefix: prefix, with: .success(""))
            }
        }

        func writes() -> [[String]] {
            runner.invocations.map(\.arguments).filter { $0.count > 1 && ["set", "delete"].contains($0[1]) }
        }
    }

    // gitleaks:allow (names only)
    static let confirmedSecrets = """
    [{"name":"NPM_TOKEN","numSelectedRepos":0,"updatedAt":"2026-08-02T10:00:00Z","visibility":"all"},
     {"name":"STRIPE_KEY","numSelectedRepos":2,"updatedAt":"2026-10-25T12:00:00Z","visibility":"selected"},
     {"name":"DEPLOY_KEY","numSelectedRepos":1,"updatedAt":"2026-10-25T12:00:00Z","visibility":"selected"}]
    """
    static let confirmedVariables = """
    [{"createdAt":"2026-08-01T10:00:00Z","name":"REGION","numSelectedRepos":2,"updatedAt":"2026-10-25T12:00:00Z","value":"eu-north","visibility":"selected"}]
    """

    @Test func writesSendTheCompleteAccessThenTheListingConfirmsThem() async throws {
        let fixture = try await Fixture.make()
        let items = fixture.items
        let base = fixture.base
        try items.setValue(try await base.item("REGION", .variable).id, value: base.value("eu-north"))
        try items.setValue(try await base.item("STRIPE_KEY").id, value: base.value("FXV_FIXTURE_SECRET"))
        try items.setAccess(try await base.item("NPM_TOKEN").id, .private)
        try items.addItem(organizationID: fixture.organizationID, kind: .secret, name: "DEPLOY_KEY", value: base.value("FXV_FIXTURE_DEPLOY"), access: .selected(["api"]))
        try items.deleteItems([try await base.item("FXV_FIXTURE_URL", .variable).id])

        base.base.scriptLists()
        let review = await fixture.sync.review(organizationID: fixture.organizationID)
        #expect(review.login == OrganizationRepositoryTests.organization)
        #expect(review.changes.map(\.name) == ["DEPLOY_KEY", "REGION", "STRIPE_KEY", "FXV_FIXTURE_URL"])
        #expect(review.changes.map(\.operation) == [.add, .update, .update, .delete])
        #expect(review.blocked.map(\.change.name) == ["NPM_TOKEN"])
        #expect(review.blocked.first?.reason == .valueMissing, "an access change needs the secret's value")

        fixture.scriptRepositories(of: "REGION", ["api", "web"])
        fixture.scriptRepositories(of: "STRIPE_KEY", ["api", "web"])
        fixture.scriptWritesSucceed()
        base.base.scriptLists(secrets: Self.confirmedSecrets, variables: Self.confirmedVariables)
        let result = await fixture.sync.run(review, includeDeletions: true)
        #expect(result.doneCount == 4)
        #expect(fixture.writes() == [
            ["secret", "set", "DEPLOY_KEY", "--org=example-org", "--visibility=selected", "--repos=api"],
            ["variable", "set", "REGION", "--org=example-org", "--visibility=selected", "--repos=api,web"],
            ["secret", "set", "STRIPE_KEY", "--org=example-org", "--visibility=selected", "--repos=api,web"],
            ["variable", "delete", "FXV_FIXTURE_URL", "--org=example-org"],
        ])
        let stdin = fixture.runner.invocations.first { $0.arguments.starts(with: ["secret", "set", "STRIPE_KEY"]) }?.stdin
        #expect(stdin == Data("FXV_FIXTURE_SECRET".utf8))

        let after = try await base.base.organizations.items(of: fixture.organizationID)
        #expect(after.filter { $0.syncStatus != .synced }.map(\.name) == ["NPM_TOKEN"])
        #expect(!after.contains { $0.name == "FXV_FIXTURE_URL" })
        let deploy = try await base.item("DEPLOY_KEY")
        #expect(deploy.selectedRepositoryCount == 1)
        #expect(try items.repositories(of: deploy.id).isEmpty, "the edited list is GitHub's now")
        #expect(try items.pendingCounts() == [fixture.organizationID: 1])
    }

    @Test func reviewBlocksWhatGitHubChangedOrAlreadyHas() async throws {
        let fixture = try await Fixture.make()
        let base = fixture.base
        try fixture.items.setValue(try await base.item("REGION", .variable).id, value: base.value("eu-north"))
        try fixture.items.addItem(organizationID: fixture.organizationID, kind: .secret, name: "DEPLOY_KEY", value: base.value("x"), access: .all)
        base.base.scriptLists(secrets: Self.confirmedSecrets, variables: Self.confirmedVariables)
        let review = await fixture.sync.review(organizationID: fixture.organizationID)
        #expect(review.changes.isEmpty)
        #expect(Dictionary(uniqueKeysWithValues: review.blocked.map { ($0.change.name, $0.reason) }) == [
            "REGION": .remoteChanged, "DEPLOY_KEY": .existsRemotely,
        ])

        // A listing that fails blocks every change with its error.
        fixture.runner.enqueue(.failure(exitCode: 1, stderr: "gh: Bad credentials (HTTP 401)"), matching: { $0.starts(with: ["secret", "list"]) })
        let failed = await fixture.sync.review(organizationID: fixture.organizationID)
        #expect(failed.blocked.count == 2)
        #expect(failed.blocked.allSatisfy { if case .listingFailed = $0.reason { true } else { false } })
    }

    @Test func aSelectedItemWithNoRepositoriesIsNotWrittenAndDeletionsWaitToBeIncluded() async throws {
        let fixture = try await Fixture.make()
        let base = fixture.base
        try fixture.items.setValue(try await base.item("REGION", .variable).id, value: base.value("eu-north"))
        try fixture.items.deleteItems([try await base.item("NPM_TOKEN").id])
        base.base.scriptLists()
        let review = await fixture.sync.review(organizationID: fixture.organizationID)
        #expect(review.changes.count == 2)

        fixture.scriptRepositories(of: "REGION", [])
        fixture.scriptWritesSucceed()
        let result = await fixture.sync.run(review, includeDeletions: false)
        #expect(result.outcomes[try await base.item("REGION", .variable).id] == .blocked(.noRepositories))
        #expect(result.outcomes[try await base.item("NPM_TOKEN").id] == .skipped)
        #expect(fixture.writes().isEmpty)
    }
}
