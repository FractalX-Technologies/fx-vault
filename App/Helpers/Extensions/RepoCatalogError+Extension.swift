import VaultCore
import VaultData

nonisolated extension RepoCatalogError {
    var presentation: ErrorPresentationModel {
        switch self {
        case .github(let error):
            error.presentation
        case .vault(let error):
            error.presentation
        case .alreadyImported:
            ErrorPresentationModel(
                title: String(localized: "error.catalog.alreadyImported.title", defaultValue: "Already in the vault"),
                message: String(
                    localized: "error.catalog.alreadyImported",
                    defaultValue: "This repository is already imported. Use Refresh to read GitHub again."
                )
            )
        case .repositoryNotFound:
            ErrorPresentationModel(
                title: String(localized: "error.catalog.title", defaultValue: "Repository not available"),
                message: String(localized: "error.config.repositoryNotFound", defaultValue: "This repository is no longer in the vault.")
            )
        case .organizationAlreadyImported:
            ErrorPresentationModel(
                title: String(localized: "error.catalog.alreadyImported.title", defaultValue: "Already in the vault"),
                message: String(
                    localized: "error.organization.alreadyImported",
                    defaultValue: "This organization is already imported."
                )
            )
        case .organizationNotFound:
            ErrorPresentationModel(
                title: String(localized: "error.organization.title", defaultValue: "Organization not available"),
                message: String(localized: "error.organization.notFound", defaultValue: "This organization is no longer in the vault.")
            )
        case .store, .encryptionFailed, .unexpected:
            ErrorPresentationModel(
                title: String(localized: "error.catalog.title", defaultValue: "Repository not available"),
                message: String(
                    localized: "error.catalog.storage",
                    defaultValue: "The vault could not store the repository. Try again; if it keeps happening, quit and reopen FX Vault."
                )
            )
        }
    }
}
