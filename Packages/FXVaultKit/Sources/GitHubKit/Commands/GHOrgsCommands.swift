import Foundation
import os
import VaultCore

/// `gh org list` (tasks/todo.md §8 A5).
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
