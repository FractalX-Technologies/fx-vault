import SyncEngine
import VaultCore
import VaultData

nonisolated extension DriftRepositoryError {
    var presentation: ErrorPresentationModel {
        switch self {
        case .github(let error):
            error.presentation
        case .config(let error):
            error.presentation
        case .vault(let error):
            error.presentation
        case .validation(let error):
            error.presentation
        default:
            ErrorPresentationModel(
                title: String(localized: "error.drift.title", defaultValue: "GitHub changes not checked"),
                message: localizedMessage
            )
        }
    }

    var localizedMessage: String {
        switch self {
        case .repositoryNotFound:
            String(localized: "error.config.repositoryNotFound", defaultValue: "This repository is no longer in the vault.")
        case .resolutionUnavailable(.valueMissing):
            String(
                localized: "error.drift.valueMissing",
                defaultValue: "Keeping your version needs the secret's value, which FX Vault does not have. Fill it first."
            )
        case .resolutionUnavailable(.conflictsWithPendingRename):
            String(
                localized: "error.drift.pendingRename",
                defaultValue: "A pending environment rename uses this name. Change or revert that rename first."
            )
        case .stale:
            String(
                localized: "error.drift.stale",
                defaultValue: "GitHub changed again since the check. Refresh and review the changes again."
            )
        case .github(let error):
            error.localizedMessage
        case .config(let error):
            error.localizedMessage
        case .validation(let error):
            error.localizedMessage
        case .vault(let error):
            error.localizedMessage
        case .sync(.github(let error)):
            error.localizedMessage
        case .store, .sync, .unexpected:
            String(
                localized: "error.drift.storage",
                defaultValue: "The vault could not save the resolution. Try again; if it keeps happening, quit and reopen FX Vault."
            )
        }
    }
}
