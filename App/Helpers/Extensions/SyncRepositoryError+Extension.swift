import SyncEngine
import VaultCore
import VaultData

nonisolated extension SyncRepositoryError {
    var presentation: ErrorPresentationModel {
        switch self {
        case .vault(let error):
            return error.presentation
        case .sync(.github(let error)):
            return error.presentation
        case .sync(.locked):
            return VaultError.locked.presentation
        default:
            return ErrorPresentationModel(
                title: String(localized: "error.sync.title", defaultValue: "Sync did not run"),
                message: localizedMessage
            )
        }
    }

    var localizedMessage: String {
        switch self {
        case .alreadyRunning, .sync(.alreadyRunning):
            String(localized: "error.sync.alreadyRunning", defaultValue: "A sync is already running.")
        case .sync(.accountUnavailable(let login)):
            String(
                localized: "error.sync.accountUnavailable",
                defaultValue: "\(login) is not logged in to the GitHub CLI. Log it in, then sync again."
            )
        case .sync(.valueUnavailable):
            String(
                localized: "error.sync.valueUnavailable",
                defaultValue: "A value FX Vault needs is missing. Fill it, then sync again."
            )
        case .sync(.github(let error)):
            error.localizedMessage
        case .vault(let error):
            error.localizedMessage
        case .sync(.locked):
            VaultError.locked.localizedMessage
        case .sync(.persistenceFailed), .store, .unexpected:
            String(
                localized: "error.sync.storage",
                defaultValue: "The vault could not record the sync. Try again; if it keeps happening, quit and reopen FX Vault."
            )
        }
    }
}
