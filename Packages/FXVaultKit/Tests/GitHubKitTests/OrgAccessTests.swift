import Foundation
import Testing
@testable import GitHubKit
import VaultCore

/// Organization access (1.0, tasks/todo.md B4): A6 reads the account's role, and the rule
/// combines it with the token's scopes.
@Suite("Organization access")
struct OrgAccessTests {
    private static let admin = GHOrgMembershipDTO(state: "active", role: "admin")
    private static let member = GHOrgMembershipDTO(state: "active", role: "member")
    private static let invitedAdmin = GHOrgMembershipDTO(state: "pending", role: "admin")
    private static let ssoPage = URL(string: "https://github.com/orgs/example-sso/sso")

    @Test func membershipIsAReadOfTheTokensOwnRole() throws {
        let command = try GHOrgsCommands.membership(organization: "example-org")
        #expect(command.arguments == [
            "api",
            "-H", "Accept: \(GHConstants.acceptHeader)",
            "-H", "X-GitHub-Api-Version: \(GHConstants.apiVersion)",
            "-X", "GET",
            "user/memberships/orgs/example-org",
        ])
        #expect(command.logTemplate == "api GET user/memberships/orgs/{o}")
        #expect(!command.operation.isWrite)
        #expect(throws: GHError.self) { try GHOrgsCommands.membership(organization: "example-org/../user") }
    }

    @Test func membershipDecodesStateAndRole() throws {
        var data = Data(#"{"url":"https://api.github.com/orgs/example-org/memberships/owner-a","state":"active","role":"admin"}"#.utf8)
        let output = GHCommandOutput(operation: .orgMembership, stdout: SecretBytes(wipingSource: &data))
        let membership = try GHOrgsCommands.decodeMembership(output)
        #expect(membership == Self.admin)
        #expect(membership.isActiveAdmin)
        #expect(!Self.invitedAdmin.isActiveAdmin)
    }

    @Test(arguments: [
        (["repo", "admin:org"], Result<GHOrgMembershipDTO, GHError>.success(admin), OrgAccessStatus.ready),
        (["repo", "read:org"], .success(admin), .needsAdminOrgScope),
        // Approving a scope never helps a member, so the role is reported first.
        (["repo", "read:org"], .success(member), .needsOrgAdmin),
        (["repo", "admin:org"], .success(invitedAdmin), .needsOrgAdmin),
        (["repo", "admin:org"], .failure(.samlRequired(ssoPage)), .ssoRequired(ssoPage)),
        (["repo", "read:org"], .failure(.notFound), .needsAdminOrgScope),
        (["repo", "admin:org"], .failure(.notFound), .unknown),
    ] as [([String], Result<GHOrgMembershipDTO, GHError>, OrgAccessStatus)])
    func accessCombinesTheRoleAndTheScopes(scopes: [String], membership: Result<GHOrgMembershipDTO, GHError>, expected: OrgAccessStatus) {
        #expect(OrgAccessChecker.status(scopes: scopes, membership: membership) == expected)
    }

    @Test func aFineGrainedTokenIsUnknown() {
        #expect(OrgAccessChecker.status(scopes: nil, membership: .success(Self.admin)) == .unknown)
        #expect(OrgAccessChecker.status(scopes: nil, membership: .success(Self.member)) == .needsOrgAdmin)
    }

    @Test func adminOrgIsRequestedOnTheAccountThenTheActiveOneComesBack() {
        #expect(ScopeChecker.fixCommands(login: "user-b", previousActiveLogin: "user-a", scopes: [ScopeChecker.adminOrgScope]) == [
            "gh auth switch -h github.com -u user-b",
            "gh auth refresh -h github.com -s admin:org",
            "gh auth switch -h github.com -u user-a",
        ])
    }
}
