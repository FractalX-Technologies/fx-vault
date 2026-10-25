import Foundation
import GitHubKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// The Connect phase after onboarding (tasks/todo.md B11d2): sources by account, the ready ones
/// checked, the import of the checked ones and its summary.
@MainActor
@Suite("Connect")
struct ConnectViewModelTests {
    /// user-a can manage example-org's secrets (admin:org, admin role); example-labs needs an
    /// org admin. user-b has no organizations.
    static func scripted() async throws -> TestHarness {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        try harness.installFakeGH()
        harness.stubAuthStatus("""
        {"hosts":{"github.com":[
         {"state":"success","active":true,"host":"github.com","login":"user-a","tokenSource":"keyring","scopes":"admin:org, read:org, repo","gitProtocol":"ssh"},
         {"state":"success","active":false,"host":"github.com","login":"user-b","tokenSource":"keyring","scopes":"read:org, repo","gitProtocol":"ssh"}
        ]}}
        """)
        harness.stubToken()
        harness.runner.stub(argumentsPrefix: ["org", "list"], with: .success("example-org\nexample-labs\n"))
        harness.runner.respond(argumentsPrefix: ["api"]) { invocation in
            invocation.arguments.last == "user/memberships/orgs/example-org"
                ? .success(#"{"state":"active","role":"admin"}"#)
                : .success(#"{"state":"active","role":"member"}"#)
        }
        harness.runner.stub(
            argumentsPrefix: ["repo", "list", "user-a"],
            with: .success("[\(TestFixtures.repoJSON(owner: "user-a", name: "dotfiles", permission: "ADMIN"))]")
        )
        harness.runner.stub(argumentsPrefix: ["repo", "list"], with: .success("[]"))
        harness.runner.stub(argumentsPrefix: ["secret", "list", "--org=example-org"], with: .success(OrganizationViewModelTests.secrets))
        harness.runner.stub(argumentsPrefix: ["variable", "list", "--org=example-org"], with: .success(OrganizationViewModelTests.variables))
        await harness.app.refreshGHStatus()
        return harness
    }

    @Test func readySourcesAreCheckedAndAnOrganizationIsListedOnce() async throws {
        let harness = try await Self.scripted()
        let connect = harness.app.makeConnectViewModel()
        await connect.load()

        #expect(connect.error == nil)
        let userA = try #require(connect.sections.first { $0.accountLogin == "user-a" })
        #expect(userA.sources.map(\.login) == ["example-org", "example-labs", "user-a"])
        #expect(userA.sources.map(\.isReady) == [true, false, true])
        // user-b reaches both organizations too, but only as a member: they stay under user-a.
        let userB = try #require(connect.sections.first { $0.accountLogin == "user-b" })
        #expect(userB.sources.map(\.login) == ["user-b"])
        #expect(Set(connect.selectedSources.map(\.login)) == ["example-org", "user-a"])
    }

    @Test func anOrganizationGoesToTheAccountThatCanReadIt() {
        typealias Source = ConnectViewModel.Source
        let member = ConnectViewModel.AccountSection(
            accountLogin: "user-b",
            sources: [Source(login: "Example-Org", accountLogin: "user-b", kind: .organization(.needsOrgAdmin))]
        )
        let admin = ConnectViewModel.AccountSection(
            accountLogin: "user-a",
            sources: [Source(login: "example-org", accountLogin: "user-a", kind: .organization(.ready))]
        )
        let kept = ConnectViewModel.deduplicatingOrganizations([member, admin])
        #expect(kept.map(\.sources.count) == [0, 1])
        #expect(kept[1].sources.first?.accountLogin == "user-a")
    }

    /// The organization imports; the personal repository has no scripted reads, so its import
    /// fails, is named in the summary, and does not stop the rest.
    @Test func importStoresTheCheckedSourcesAndNamesFailures() async throws {
        let harness = try await Self.scripted()
        let connect = harness.app.makeConnectViewModel()
        await connect.load()
        let labs = try #require(connect.sections.flatMap(\.sources).first { $0.login == "example-labs" })
        connect.toggle(labs)
        #expect(!connect.selection.contains(labs.id), "A source that is not ready cannot be checked")

        await connect.importSelected()
        let summary = try #require(connect.summary)
        #expect(summary.organizationCount == 1)
        #expect(summary.organizationSecretCount == 2)
        #expect(summary.organizationVariableCount == 1)
        #expect(summary.repositoryCount == 0)
        #expect(summary.failedNames == ["user-a/dotfiles"])
        #expect(summary.totalSecretCount == 2)
        #expect(try await harness.data.organizations.organizations().map(\.login) == ["example-org"])

        connect.finish()
        #expect(!harness.app.isFirstConnectPending)
    }

    @Test func countsAgreeWithTheirNumber() {
        #expect(ConnectCopy.organizations(1) == "1 organization")
        #expect(ConnectCopy.repositories(16, environments: 1) == "16 repositories · 1 environment")
        #expect(ConnectCopy.personalRepositories(1) == "1 personal repository")
        #expect(ConnectCopy.total(secrets: 2, variables: 1) == "Total · 2 secrets · 1 variable")
    }

    @Test func nothingCheckedCannotContinueAndALockClearsTheSources() async throws {
        let harness = try await Self.scripted()
        let connect = harness.app.makeConnectViewModel()
        await connect.load()
        for source in connect.selectedSources {
            connect.toggle(source)
        }
        #expect(!connect.canContinue)
        await connect.importSelected()
        #expect(connect.summary == nil)

        harness.app.lock(trigger: .manual)
        #expect(connect.sections.isEmpty)
        #expect(connect.selection.isEmpty)
    }
}
