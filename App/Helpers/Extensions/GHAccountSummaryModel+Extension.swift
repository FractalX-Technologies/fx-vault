import GitHubKit
import SwiftUI
import VaultData

extension GHAccountSummaryModel {
    /// The token state line of Preferences › Accounts.
    var tokenStateTitle: String {
        guard let status else {
            return String(localized: "accounts.token.notLoggedIn", defaultValue: "Not logged into gh")
        }
        switch status.state {
        case .ok:
            return String(localized: "accounts.token.ok", defaultValue: "Token valid")
        case .offline:
            return String(localized: "accounts.token.offline", defaultValue: "Could not reach GitHub")
        case .reloginRequired:
            return String(localized: "accounts.token.relogin", defaultValue: "Token rejected: run gh auth login again")
        case .unexpected:
            return String(localized: "accounts.token.unexpected", defaultValue: "gh reported a problem with this account")
        }
    }

    /// Offline is nothing the user can fix here; a rejected token or no login is.
    var tokenStateMark: PreferencesStatus.Mark {
        switch status?.state {
        case .ok: .fine
        case .offline: .idle
        case .reloginRequired, .unexpected, nil: .needsYou
        }
    }

    /// "OK", "Missing: repo, read:org" or "Unknown (fine-grained token)".
    var scopesTitle: String {
        switch status?.scopes {
        case .ok:
            String(localized: "accounts.scopes.ok", defaultValue: "OK")
        case .missing(let scopes):
            String(localized: "accounts.scopes.missing", defaultValue: "Missing: \(scopes.joined(separator: ", "))")
        case .unknown, nil:
            String(localized: "accounts.scopes.unknown", defaultValue: "Unknown (the token reports no scopes)")
        }
    }

    var scopesMark: PreferencesStatus.Mark {
        switch status?.scopes {
        case .ok: .fine
        case .missing: .needsYou
        case .unknown, nil: .idle
        }
    }
}

extension SSHAliasTestResultModel {
    /// The **Test** result line (§10 Preferences › Accounts).
    var localizedMessage: String {
        switch self {
        case .authenticatedAsAccount(let login):
            String(localized: "accounts.ssh.test.ok", defaultValue: "Authenticates as \(login)")
        case .authenticatedAsOtherAccount(let login, let isLoggedIntoGH):
            isLoggedIntoGH
                ? String(
                    localized: "accounts.ssh.test.otherAccount",
                    defaultValue: "Authenticates as \(login), another account. Pick the alias of this account."
                )
                : String(
                    localized: "accounts.ssh.test.notInGH",
                    defaultValue: "Authenticates as \(login), which is not logged in to the GitHub CLI. Log it in with gh auth login, then pick this alias for that account."
                )
        case .notGitHub(let hostName):
            String(localized: "accounts.ssh.test.notGitHub", defaultValue: "This alias points to \(hostName), not github.com")
        case .permissionDenied:
            String(localized: "accounts.ssh.test.denied", defaultValue: "Permission denied: no usable SSH key for this alias")
        case .hostKeyUnknown:
            String(
                localized: "accounts.ssh.test.hostKey",
                defaultValue: "GitHub's host key is not known yet. Run ssh -T git@<alias> once in Terminal."
            )
        case .timeout:
            String(localized: "accounts.ssh.test.timeout", defaultValue: "ssh did not answer in time")
        case .failed(let exitCode):
            String(localized: "accounts.ssh.test.failed", defaultValue: "ssh failed (exit code \(exitCode))")
        }
    }
}
