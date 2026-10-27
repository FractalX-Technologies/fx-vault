import Foundation
import VaultData

/// Choose Repositories…'s texts.
enum ChooseRepositoriesCopy {
    static let menu = String(localized: "settings.accounts.chooseRepositories", defaultValue: "Choose Repositories…")
    static let title = String(localized: "settings.accounts.chooseRepositories.title", defaultValue: "Choose Repositories")
    static let search = String(localized: "settings.accounts.chooseRepositories.search", defaultValue: "Search repositories")
    static let add = String(localized: "settings.accounts.chooseRepositories.add", defaultValue: "Add Repositories")
    static let empty = String(localized: "settings.accounts.chooseRepositories.empty", defaultValue: "This account lists no repository.")
    static let noMatches = String(localized: "settings.accounts.chooseRepositories.noMatches", defaultValue: "No repository matches the search.")

    static func importing(_ fullName: String) -> String {
        String(localized: "settings.accounts.chooseRepositories.importing", defaultValue: "Adding \(fullName)…")
    }

    /// The row's subline: in FX Vault already, else private or public, archived, fork.
    static func detail(_ repository: CatalogRepoModel) -> String {
        if repository.isImported {
            return String(localized: "settings.accounts.chooseRepositories.added", defaultValue: "Already in FX Vault")
        }
        var parts = [
            repository.visibility.isPrivate
                ? String(localized: "settings.accounts.chooseRepositories.private", defaultValue: "Private")
                : String(localized: "settings.accounts.chooseRepositories.public", defaultValue: "Public"),
        ]
        if repository.isArchived {
            parts.append(String(localized: "settings.accounts.chooseRepositories.archived", defaultValue: "Archived"))
        }
        if repository.isFork {
            parts.append(String(localized: "settings.accounts.chooseRepositories.fork", defaultValue: "Fork"))
        }
        return parts.joined(separator: " · ")
    }

    static func result(_ result: ChooseRepositoriesModel.ImportResult) -> String {
        var parts: [String] = []
        if result.importedCount > 0 {
            parts.append(String(inflected: AttributedString(
                localized: "settings.accounts.chooseRepositories.result",
                defaultValue: "Added ^[\(result.importedCount) repository](inflect: true) to FX Vault."
            )))
        }
        if !result.failedNames.isEmpty {
            parts.append(String(
                localized: "settings.accounts.chooseRepositories.failed",
                defaultValue: "Could not add \(result.failedNames.formatted(.list(type: .and)))."
            ))
        }
        return parts.joined(separator: " ")
    }
}
