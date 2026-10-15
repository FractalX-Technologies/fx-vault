import SyncEngine
import VaultCore
import VaultData

nonisolated extension ConfigRepositoryError {
    var presentation: ErrorPresentationModel {
        switch self {
        case .vault(let error):
            error.presentation
        case .validation(let error):
            error.presentation
        case .edit(.invalidName(let error)):
            error.presentation
        default:
            ErrorPresentationModel(
                title: String(localized: "error.config.title", defaultValue: "The change was not saved"),
                message: localizedMessage
            )
        }
    }

    var localizedMessage: String {
        switch self {
        case .repositoryNotFound:
            String(localized: "error.config.repositoryNotFound", defaultValue: "This repository is no longer in the vault.")
        case .environmentNotFound:
            String(localized: "error.config.environmentNotFound", defaultValue: "This environment is no longer in the vault.")
        case .itemNotFound, .edit(.itemNotFound):
            String(localized: "error.config.itemNotFound", defaultValue: "This item is no longer in the vault.")
        case .environmentDeleted:
            String(
                localized: "error.config.environmentDeleted",
                defaultValue: "This environment is deleted. Revert it first to change its items."
            )
        case .readOnly(let reason):
            reason.localizedExplanation
        case .valueMissing:
            String(
                localized: "error.config.valueMissing",
                defaultValue: "This secret has no value in FX Vault (GitHub never returns secret values). Fill its value first."
            )
        case .validation(let error), .edit(.invalidName(let error)):
            error.localizedMessage
        case .tooManyBranchPatterns(let limit):
            String(localized: "error.config.tooManyPatterns", defaultValue: "An environment can have at most \(limit) branch rules.")
        case .edit(.nameTaken):
            String(localized: "error.validation.duplicateName", defaultValue: "Another item already uses this name.")
        case .edit(.nothingToRevert):
            String(localized: "error.config.nothingToRevert", defaultValue: "There is no local change to revert.")
        case .edit(.valueNotMissing):
            String(localized: "error.config.valueNotMissing", defaultValue: "This secret already has a value. Edit it instead.")
        case .vault(let error):
            error.localizedMessage
        case .store, .encryptionFailed, .unexpected:
            String(
                localized: "error.config.storage",
                defaultValue: "The vault could not save the change. Try again; if it keeps happening, quit and reopen FX Vault."
            )
        }
    }
}
