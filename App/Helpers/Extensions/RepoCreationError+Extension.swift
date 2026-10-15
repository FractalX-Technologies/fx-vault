import VaultCore
import VaultData

nonisolated extension RepoCreationError {
    var presentation: ErrorPresentationModel {
        switch self {
        case .github(let error):
            error.presentation
        case .git(let error):
            error.presentation
        case .config(let error):
            error.presentation
        case .vault(let error):
            error.presentation
        case .validation(let error):
            error.presentation
        default:
            ErrorPresentationModel(
                title: String(localized: "error.creation.title", defaultValue: "Repository not created or cloned"),
                message: localizedMessage
            )
        }
    }

    var localizedMessage: String {
        switch self {
        case .repositoryNotFound:
            String(localized: "error.config.repositoryNotFound", defaultValue: "This repository is no longer in the vault.")
        case .repositoryExists:
            String(localized: "error.creation.exists", defaultValue: "A repository with this owner and name is already in the vault.")
        case .notOnGitHub:
            String(localized: "error.creation.notOnGitHub", defaultValue: "The repository is not on GitHub yet. Sync first, then clone.")
        case .alreadyOnGitHub:
            String(localized: "error.creation.alreadyOnGitHub", defaultValue: "This repository already exists on GitHub.")
        case .sshAliasNotMapped:
            String(
                localized: "error.creation.sshAliasNotMapped",
                defaultValue: "Map an SSH alias to this repository's account in Settings › Accounts, then clone again."
            )
        case .gitUnavailable:
            String(localized: "error.creation.gitUnavailable", defaultValue: "git is not available yet. Try again in a moment.")
        case .github(let error):
            error.localizedMessage
        case .git(let error):
            error.localizedMessage
        case .config(let error):
            error.localizedMessage
        case .vault(let error):
            error.localizedMessage
        case .validation(let error):
            error.localizedMessage
        case .store, .unexpected:
            String(
                localized: "error.creation.storage",
                defaultValue: "The vault could not save the repository. Try again; if it keeps happening, quit and reopen FX Vault."
            )
        }
    }
}
