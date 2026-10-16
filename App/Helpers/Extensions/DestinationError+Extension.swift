import DestinationKit
import VaultCore
import VaultData

/// Messages for destination errors (v0.8.0). Codes only, never names or values from a response.
nonisolated extension DestinationError {
    func localizedMessage(provider: DestinationProvider) -> String {
        switch self {
        case .azNotInstalled:
            String(
                localized: "error.destination.azNotInstalled",
                defaultValue: "The Azure CLI (az) was not found. Install it with Homebrew (brew install azure-cli), then run az login."
            )
        case .azUntrusted(let path):
            String(
                localized: "error.destination.azUntrusted",
                defaultValue: "FX Vault does not run \(path): another user can change it. Reinstall the Azure CLI in a folder only you or root can write."
            )
        case .azNotSignedIn:
            String(
                localized: "error.destination.azNotSignedIn",
                defaultValue: "The Azure CLI is not signed in. Run az login in Terminal, then try again."
            )
        case .azFailed:
            String(
                localized: "error.destination.azFailed",
                defaultValue: "The Azure CLI could not give FX Vault a Key Vault token. Run az account get-access-token --resource https://vault.azure.net in Terminal to see why."
            )
        case .tokenMissing:
            String(
                localized: "error.destination.tokenMissing",
                defaultValue: "This destination has no connection. Choose one in its Settings…"
            )
        case .unauthorized:
            String(
                localized: "error.destination.unauthorized",
                defaultValue: "\(provider.title) did not accept the credentials. Replace the token in Settings › Destinations, or sign in again."
            )
        case .forbidden:
            String(
                localized: "error.destination.forbidden",
                defaultValue: "The account has no permission for this in \(provider.title) (for Key Vault: read and set secrets)."
            )
        case .notFound:
            String(
                localized: "error.destination.notFound",
                defaultValue: "\(provider.title) does not have this vault, project or item, or the account cannot see it."
            )
        case .deletedButRecoverable:
            String(
                localized: "error.destination.deletedButRecoverable",
                defaultValue: "Key Vault holds a deleted secret with this name that could not be recovered. Recover or purge it in Azure, then sync again."
            )
        case .conflict:
            String(localized: "error.destination.conflict", defaultValue: "\(provider.title) refused the change because of a conflict. Refresh, then try again.")
        case .rateLimited:
            String(localized: "error.destination.rateLimited", defaultValue: "\(provider.title) asked FX Vault to slow down. Try again in a minute.")
        case .invalidRequest:
            String(localized: "error.destination.invalidRequest", defaultValue: "\(provider.title) refused the request.")
        case .valueTooLarge:
            String(localized: "error.destination.valueTooLarge", defaultValue: "The value is too large for \(provider.title).")
        case .server:
            String(localized: "error.destination.server", defaultValue: "\(provider.title) had a problem. Try again later.")
        case .network:
            String(localized: "error.destination.network", defaultValue: "\(provider.title) could not be reached. Check the internet connection.")
        case .timeout:
            String(
                localized: "error.destination.timeout",
                defaultValue: "\(provider.title) did not answer in time. The change may have gone through: Refresh before trying again."
            )
        case .decoding, .responseTooLarge:
            String(localized: "error.destination.decoding", defaultValue: "\(provider.title) sent an answer FX Vault could not read.")
        case .cancelled:
            String(localized: "error.destination.cancelled", defaultValue: "Cancelled.")
        case .disallowedHost:
            String(localized: "error.destination.disallowedHost", defaultValue: "\(provider.title) pointed FX Vault to another server, so it stopped.")
        case .valueNotUTF8:
            String(localized: "error.destination.valueNotUTF8", defaultValue: "\(provider.title) holds a value that is not text, so FX Vault left it as it is.")
        case .invalidInput(let error):
            error.localizedMessage
        }
    }
}

nonisolated extension DestinationSyncError {
    var presentation: ErrorPresentationModel {
        switch self {
        case .config(let error):
            error.presentation
        case .remote(let error):
            ErrorPresentationModel(title: DestinationCopy.syncErrorTitle, message: error.localizedMessage(provider: .azureKeyVault))
        case .connectionMissing:
            ErrorPresentationModel(title: DestinationCopy.syncErrorTitle, message: DestinationCopy.connectionMissing)
        case .stale:
            ErrorPresentationModel(
                title: DestinationCopy.syncErrorTitle,
                message: String(
                    localized: "error.destination.stale",
                    defaultValue: "The destination changed again while you were deciding. Refresh and review once more."
                )
            )
        }
    }

    /// The presentation with the destination's provider named in the message.
    func presentation(provider: DestinationProvider) -> ErrorPresentationModel {
        if case .remote(let error) = self {
            return ErrorPresentationModel(title: DestinationCopy.syncErrorTitle, message: error.localizedMessage(provider: provider))
        }
        return presentation
    }
}

nonisolated extension DestinationUnusableReason {
    var localizedMessage: String {
        switch self {
        case .invalidName(let error):
            error.localizedMessage
        case .disabled:
            String(localized: "destination.unusable.disabled", defaultValue: "Disabled in Key Vault")
        case .managed:
            String(localized: "destination.unusable.managed", defaultValue: "Managed by a Key Vault certificate")
        case .gitBranch:
            String(localized: "destination.unusable.gitBranch", defaultValue: "Only for one Git branch in Vercel")
        case .customEnvironment:
            String(localized: "destination.unusable.customEnvironment", defaultValue: "Also used by a custom Vercel environment")
        case .system:
            String(localized: "destination.unusable.system", defaultValue: "Set by the provider itself")
        }
    }
}
