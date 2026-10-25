import Foundation
import os
import VaultCore

/// `gh org list` (tasks/todo.md §8 A5) and the account's role in one organization (A6).
///
/// gh has no `--json` here: with non-TTY stdout it prints one login per line. Each login is
/// validated; invalid lines are skipped. Only orgs the account is a member of are listed, and
/// without `read:org` the list can be incomplete without any error.
public enum GHOrgsCommands {
    /// A5: `gh org list --limit <Limits.orgListMax>`.
    public static func list() throws(GHError) -> GHCommand {
        try GHCommand(
            operation: .orgList,
            arguments: ["org", "list", "--limit", String(Limits.orgListMax)],
            logTemplate: "org list --limit \(Limits.orgListMax)"
        )
    }

    /// A6: `gh api ... -X GET user/memberships/orgs/{org}`. Organization secrets need the `admin`
    /// role; a 404 means the account is not a member.
    public static func membership(organization: String) throws(GHError) -> GHCommand {
        let organization = try GHReposCommands.validatedOwner(organization)
        return try GHCommand(
            operation: .orgMembership,
            arguments: GHEnvironmentsAPI.apiArguments(method: "GET", path: try GitHubPath.orgMembership(organization)),
            logTemplate: "api GET user/memberships/orgs/{o}"
        )
    }

    /// Decodes A6 and wipes stdout.
    public static func decodeMembership(_ output: GHCommandOutput) throws(GHError) -> GHOrgMembershipDTO {
        defer { output.wipe() }
        return try GHJSONDecoding.decode(GHOrgMembershipDTO.self, from: output.stdout)
    }

    /// The valid logins in A5's output, in order, without duplicates (case-insensitive).
    public static func parseList(_ text: String) -> [String] {
        var seen: Set<String> = []
        var logins: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let login = rawLine.trimmingCharacters(in: .whitespaces)
            guard OwnerLoginValidator.isValid(login),
                  seen.insert(OwnerLoginValidator.foldKey(login)).inserted
            else { continue }
            logins.append(login)
        }
        return logins
    }

    /// Decodes A5 and wipes stdout.
    public static func decodeList(_ output: GHCommandOutput) -> [String] {
        defer { output.wipe() }
        let text = output.stdout.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        let logins = parseList(text)
        GHLog.gh.info("org list: \(logins.count, privacy: .public) valid logins")
        return logins
    }
}
