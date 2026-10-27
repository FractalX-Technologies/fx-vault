import Foundation
import GitHubKit
import Observation
import VaultCore
import VaultData

/// Settings › Accounts › Choose Repositories… (1.0.3): one gh account's repositories by owner,
/// searchable, with a checkbox each. The ones already in FX Vault stay checked and disabled, so
/// none is imported twice; Add Repositories imports the rest one by one, like the sidebar's
/// Import. Nothing changes on GitHub.
@Observable
final class ChooseRepositoriesModel {
    /// One owner of the account's catalog, with the repositories the search keeps.
    struct Owner: Identifiable, Equatable {
        let id: String
        let login: String
        let repositories: [CatalogRepoModel]
        /// gh could not list this owner (SSO, for example).
        let failure: ErrorPresentationModel?
    }

    /// What one Add Repositories did.
    struct ImportResult: Equatable {
        var importedCount = 0
        var failedNames: [String] = []
    }

    let accountLogin: String
    /// The search: it filters the list, never the selection.
    var query = ""
    private(set) var selection: Set<CatalogRepoModel.ID> = []
    private(set) var catalog: AccountCatalogModel?
    private(set) var isLoading = false
    private(set) var isImporting = false
    /// The repository being imported, for the sheet's footer.
    private(set) var importingName: String?
    private(set) var failure: ErrorPresentationModel?

    @ObservationIgnored private let catalogRepository: RepoCatalogRepository
    /// Checked before each import: a lock stops the run, so nothing reads gh or writes the
    /// vault after it.
    @ObservationIgnored private let isUnlocked: () -> Bool

    init(accountLogin: String, catalog: RepoCatalogRepository, isUnlocked: @escaping () -> Bool) {
        self.accountLogin = accountLogin
        catalogRepository = catalog
        self.isUnlocked = isUnlocked
    }

    // MARK: - Content

    /// The owners with the repositories whose `owner/name` matches the search; while searching,
    /// an owner left without one is dropped.
    var visibleOwners: [Owner] {
        let search = SearchQuery(query)
        return (catalog?.owners ?? []).compactMap { owner in
            let repositories = owner.repositories
                .filter { search.matches("\(owner.login)/\($0.ref.name)") }
                .sorted { $0.ref.name.localizedCaseInsensitiveCompare($1.ref.name) == .orderedAscending }
            guard !repositories.isEmpty || search.isEmpty else { return nil }
            return Owner(id: owner.id, login: owner.login, repositories: repositories, failure: owner.failure?.presentation)
        }
    }

    /// The search field shows once there is more than one repository to look through.
    var isSearchable: Bool {
        (catalog?.owners.flatMap(\.repositories).count ?? 0) > SearchQuery.fieldThreshold
    }

    /// The note in place of the list: nothing listed, or nothing matching the search; nil while
    /// loading or when an owner's failure already explains the gap.
    var emptyNote: String? {
        let owners = visibleOwners
        guard hasLoaded, failure == nil, owners.allSatisfy({ $0.repositories.isEmpty && $0.failure == nil }) else { return nil }
        return SearchQuery(query).isEmpty ? ChooseRepositoriesCopy.empty : ChooseRepositoriesCopy.noMatches
    }

    var hasLoaded: Bool {
        catalog != nil || failure != nil
    }

    func isSelected(_ repository: CatalogRepoModel) -> Bool {
        repository.isImported || selection.contains(repository.id)
    }

    /// The chosen repositories not yet in FX Vault, in list order.
    var selectedRepositories: [CatalogRepoModel] {
        (catalog?.owners ?? []).flatMap(\.repositories).filter { !$0.isImported && selection.contains($0.id) }
    }

    func toggle(_ repository: CatalogRepoModel) {
        guard !repository.isImported, !isImporting else { return }
        if selection.contains(repository.id) {
            selection.remove(repository.id)
        } else {
            selection.insert(repository.id)
        }
    }

    // MARK: - Actions

    /// Lists the account's repositories through gh.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            catalog = try await catalogRepository.catalog(accountLogin: accountLogin)
            failure = nil
        } catch {
            failure = error.presentation
        }
    }

    /// Imports every chosen repository through the account; one that fails is named in the
    /// result and the rest still import.
    func importSelected() async -> ImportResult {
        var result = ImportResult()
        guard !isImporting else { return result }
        isImporting = true
        defer {
            isImporting = false
            importingName = nil
        }
        for repository in selectedRepositories {
            guard !Task.isCancelled, isUnlocked() else { break }
            importingName = repository.ref.fullName
            do {
                try await catalogRepository.importRepository(repository.ref, accountLogin: accountLogin)
                result.importedCount += 1
            } catch .alreadyImported(_) {
                // Imported from the sidebar meanwhile: it is in FX Vault, as asked.
                result.importedCount += 1
            } catch {
                result.failedNames.append(repository.ref.fullName)
            }
            selection.remove(repository.id)
        }
        return result
    }
}
