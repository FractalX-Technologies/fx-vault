import Foundation
import GitHubKit
import VaultCore

nonisolated extension GHError {
    var presentation: ErrorPresentationModel {
        ErrorPresentationModel(title: localizedTitle, message: localizedMessage)
    }

    var localizedTitle: String {
        switch self {
        case .notInstalled, .untrustedBinary, .versionTooOld, .launchFailed:
            String(localized: "error.gh.title.cli", defaultValue: "GitHub CLI unavailable")
        case .notAuthenticated, .tokenRevoked, .missingScopes, .samlRequired:
            String(localized: "error.gh.title.auth", defaultValue: "GitHub sign-in needed")
        case .adminRequired, .writeAccessRequired, .orgPolicyForbidsCreate, .planGated:
            String(localized: "error.gh.title.permission", defaultValue: "Not allowed on GitHub")
        case .network, .timeout, .indeterminate, .rateLimited, .serverError, .writeBudgetExhausted:
            String(localized: "error.gh.title.unreachable", defaultValue: "GitHub did not answer")
        case .notFound:
            String(localized: "error.gh.title.notFound", defaultValue: "Not found on GitHub")
        case .validation, .invalidInput:
            String(localized: "error.gh.title.rejected", defaultValue: "GitHub rejected the request")
        case .forbiddenArgument, .malformedOutput, .outputTooLarge, .unexpected, .cancelled:
            String(localized: "error.gh.title.unexpected", defaultValue: "GitHub CLI error")
        }
    }

    var localizedMessage: String {
        switch self {
        case .notInstalled:
            String(localized: "error.gh.notInstalled", defaultValue: "The GitHub CLI was not found. Install it with: brew install gh")
        case .untrustedBinary(let path):
            String(
                localized: "error.gh.untrustedBinary",
                defaultValue: "The GitHub CLI at \(path) can be changed by other users, so FX Vault does not run it."
            )
        case .versionTooOld(let found, let required):
            String(
                localized: "error.gh.versionTooOld",
                defaultValue: "GitHub CLI \(found.description) is too old; FX Vault needs \(required.description) or later. Run: brew upgrade gh"
            )
        case .notAuthenticated:
            String(localized: "error.gh.notAuthenticated", defaultValue: "No account is logged in to the GitHub CLI. Run: gh auth login")
        case .tokenRevoked:
            String(
                localized: "error.gh.tokenRevoked",
                defaultValue: "GitHub rejected this account's token. Run gh auth login again for it."
            )
        case .missingScopes(let scopes):
            scopes.isEmpty
                ? String(
                    localized: "error.gh.missingScopes.unnamed",
                    defaultValue: "The account's token lacks a required scope. See Settings › Accounts."
                )
                : String(
                    localized: "error.gh.missingScopes",
                    defaultValue: "The account's token lacks \(scopes.joined(separator: ", ")). See Settings › Accounts."
                )
        case .adminRequired:
            String(localized: "error.gh.adminRequired", defaultValue: "This needs admin rights on the repository.")
        case .writeAccessRequired:
            String(localized: "error.gh.writeAccessRequired", defaultValue: "This account cannot change this repository.")
        case .samlRequired:
            String(
                localized: "error.gh.samlRequired",
                defaultValue: "The organization requires SAML single sign-on. Authorize the account's token for it on github.com."
            )
        case .planGated:
            String(
                localized: "error.gh.planGated",
                defaultValue: "The repository's GitHub plan does not include this feature (for example environments on a private repository)."
            )
        case .orgPolicyForbidsCreate:
            String(
                localized: "error.gh.orgPolicyForbidsCreate",
                defaultValue: "The organization does not allow this account to create repositories with this visibility."
            )
        case .notFound:
            String(
                localized: "error.gh.notFound",
                defaultValue: "GitHub could not find it, or this account cannot see it."
            )
        case .validation(let message):
            String(localized: "error.gh.validation", defaultValue: "GitHub said: \(message)")
        case .rateLimited:
            String(localized: "error.gh.rateLimited", defaultValue: "GitHub's rate limit was reached. Try again in a few minutes.")
        case .serverError:
            String(localized: "error.gh.serverError", defaultValue: "GitHub had a server error. Try again in a moment.")
        case .network:
            String(localized: "error.gh.network", defaultValue: "GitHub could not be reached. Check your internet connection.")
        case .timeout:
            String(localized: "error.gh.timeout", defaultValue: "GitHub took too long to answer. Try again.")
        case .indeterminate:
            String(
                localized: "error.gh.indeterminate",
                defaultValue: "GitHub did not confirm the change in time. FX Vault checks it again on the next Sync."
            )
        case .invalidInput(let error):
            error.localizedMessage
        case .writeBudgetExhausted:
            String(
                localized: "error.gh.writeBudgetExhausted",
                defaultValue: "FX Vault's hourly write limit for this account is used up. The rest stays pending for the next Sync."
            )
        case .launchFailed:
            String(localized: "error.gh.launchFailed", defaultValue: "The GitHub CLI could not be started.")
        case .cancelled:
            String(localized: "error.gh.cancelled", defaultValue: "The GitHub CLI call was cancelled.")
        case .forbiddenArgument, .malformedOutput, .outputTooLarge, .unexpected:
            String(
                localized: "error.gh.unexpected",
                defaultValue: "The GitHub CLI failed unexpectedly. Try again; if it keeps happening, check gh in Terminal."
            )
        }
    }
}
