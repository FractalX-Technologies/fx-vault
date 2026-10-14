import Foundation
import VaultCore

/// Whether an account's token has the scopes FX Vault needs (tasks/todo.md §2, §8 A3).
public enum ScopeStatus: Sendable, Hashable {
    /// `repo` plus one of `read:org`, `write:org`, `admin:org`.
    case ok
    /// The listed scopes are missing (`repo`, and `read:org` when no org scope is present).
    case missing([String])
    /// The token reported no scopes (fine-grained tokens, or the field was absent).
    case unknown
}

/// Parses the `scopes` field of `gh auth status --json hosts` and checks the requirement.
public enum ScopeChecker {
    /// Always required.
    public static let repoScope = "repo"
    /// Any one of these satisfies the organization requirement.
    public static let orgScopes: Set<String> = ["read:org", "write:org", "admin:org"]
    /// The organization scope requested when none is present.
    public static let suggestedOrgScope = "read:org"

    /// Splits the raw `X-OAuth-Scopes` value (`gist, read:org, repo`) on `,` and trims each
    /// entry. Nil (unknown) when the value is absent or empty.
    public static func parse(_ header: String?) -> [String]? {
        guard let header else { return nil }
        let scopes = header.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return scopes.isEmpty ? nil : scopes
    }

    /// Checks the raw scopes value.
    public static func check(_ header: String?) -> ScopeStatus {
        guard let scopes = parse(header) else { return .unknown }
        return check(scopes: Set(scopes))
    }

    /// Checks parsed scopes.
    public static func check(scopes: Set<String>) -> ScopeStatus {
        var missing: [String] = []
        if !scopes.contains(repoScope) {
            missing.append(repoScope)
        }
        if scopes.isDisjoint(with: orgScopes) {
            missing.append(suggestedOrgScope)
        }
        return missing.isEmpty ? .ok : .missing(missing)
    }

    /// The copyable commands that fix the scopes of `login` without a `--user` flag
    /// (`gh auth refresh` works only on the active account, §2): switch to it, refresh, and
    /// switch back to `previousActiveLogin` when that is another account.
    public static func fixCommands(login: String, previousActiveLogin: String?) -> [String] {
        let host = GHConstants.host
        let requested = ([repoScope, suggestedOrgScope]).joined(separator: ",")
        var commands = [
            "gh auth switch -h \(host) -u \(login)",
            "gh auth refresh -h \(host) -s \(requested)",
        ]
        if let previousActiveLogin,
           OwnerLoginValidator.foldKey(previousActiveLogin) != OwnerLoginValidator.foldKey(login)
        {
            commands.append("gh auth switch -h \(host) -u \(previousActiveLogin)")
        }
        return commands
    }
}
