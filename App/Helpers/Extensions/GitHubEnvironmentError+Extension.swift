import VaultCore
import VaultData

nonisolated extension GitHubEnvironmentError {
    var presentation: ErrorPresentationModel {
        switch self {
        case .github(let error):
            error.presentation
        case .ssh(let error):
            error.presentation
        case .accountNotFound:
            ErrorPresentationModel(
                title: String(localized: "error.accounts.title", defaultValue: "Account not available"),
                message: String(
                    localized: "error.accounts.notFound",
                    defaultValue: "This account is no longer known to FX Vault. Re-check the accounts."
                )
            )
        case .store, .unexpected:
            ErrorPresentationModel(
                title: String(localized: "error.accounts.title", defaultValue: "Account not available"),
                message: String(
                    localized: "error.accounts.storage",
                    defaultValue: "The account could not be saved. Try again; if it keeps happening, quit and reopen FX Vault."
                )
            )
        }
    }
}
