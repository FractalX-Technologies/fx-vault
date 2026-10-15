import Foundation
import GitHubKit
import Observation
import VaultCore
import VaultData

/// Column 1 (§10): accounts, owner groups and repositories, with search, Import, Clone, Remove
/// from vault and Add repository by name.
///
/// - Vault repositories are observed (`ConfigRepository.observeRepositories()`), so imports,
///   removals and created repositories appear at once and work without gh.
/// - Accounts and catalogs come from gh (`GitHubEnvironmentRepository.accounts()`,
///   `RepoCatalogRepository.catalog(accountLogin:)`) and load when gh is ready.
@Observable
final class SidebarViewModel {
    var searchText = ""
    var selectedRowID: SidebarRepoModel.ID? {
        didSet {
            if selectedRowID != oldValue {
                onChange?()
            }
        }
    }
    private(set) var input = SidebarInputModel()
    private(set) var isLoadingCatalog = false
    /// Why accounts could not be listed at all; nil when they were (or gh is not ready).
    private(set) var accountsError: ErrorPresentationModel?
    /// Per-account catalog failures, by account fold key.
    private(set) var catalogErrors: [String: ErrorPresentationModel] = [:]
    /// Rows with an import, removal or clone in flight (by repo fold key).
    private(set) var busyRepoKeys: Set<String> = []
    var alert: ErrorPresentationModel?
    /// A short confirmation shown under the list ("Cloned to …", "Imported with …").
    var notice: String?
    /// The repository waiting for the "Remove from vault?" confirmation.
    var pendingRemoval: SidebarRepoModel?

    /// Called after the selection or the vault repositories changed (the main window then
    /// follows the selected repository).
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let app: AppViewModel
    @ObservationIgnored private let tasks = TaskBag()
    /// A repository to select once the vault observation delivers it (``select(repositoryID:)``).
    @ObservationIgnored private var pendingSelection: RepoID?

    init(app: AppViewModel) {
        self.app = app
        observeVault()
    }

    private var data: VaultDataComponents {
        app.container.data
    }

    // MARK: - Content

    var sections: [SidebarAccountModel] {
        SidebarGrouping.sections(input, query: searchText)
    }

    /// The selected row (searched in the unfiltered tree, so a search never loses it).
    var selectedRepo: SidebarRepoModel? {
        guard let selectedRowID else { return nil }
        return SidebarGrouping.sections(input, query: "")
            .lazy
            .flatMap(\.owners)
            .flatMap(\.repos)
            .first { $0.id == selectedRowID }
    }

    /// The vault row of an imported repository.
    func vaultRepository(_ id: RepoID) -> RepoModel? {
        input.vaultRepos.first { $0.id == id }
    }

    var isUnlocked: Bool {
        app.phase == .unlocked
    }

    var isGitHubReady: Bool {
        app.ghStatus.isReady
    }

    /// False while the Mac has no internet connection (v0.2.0): every gh-backed row action is
    /// disabled and the lists load again when it returns.
    var isOnline: Bool {
        app.container.connectivity.isOnline
    }

    private var gitHubReachability: GitHubReachability {
        app.container.gitHubReachability
    }

    /// "Add repository by name…" needs gh and the internet.
    var canAddByName: Bool {
        isUnlocked && isGitHubReady && isOnline
    }

    /// True when the accounts or a catalog could not be listed (or never were), so the lists
    /// load again when the connection returns.
    var needsReload: Bool {
        input.accounts.isEmpty || accountsError != nil || !catalogErrors.isEmpty
    }

    func catalogError(for accountID: SidebarAccountModel.ID) -> ErrorPresentationModel? {
        catalogErrors[accountID]
    }

    func isBusy(_ repo: SidebarRepoModel) -> Bool {
        busyRepoKeys.contains(repo.repoKey)
    }

    // MARK: - Loading

    private func observeVault() {
        let stream = data.config.observeRepositories()
        tasks.set("vault", Task { [weak self] in
            do {
                for try await repos in stream {
                    guard let self else { return }
                    input.vaultRepos = repos
                    applyPendingSelection()
                    onChange?()
                }
            } catch {
                AppLog.ui.error("Repository observation ended")
            }
        })
    }

    /// Lists the gh accounts and each logged-in account's catalog. Does nothing until gh is ready
    /// or while offline. Catalog results feed `GitHubReachability`.
    func reload() async {
        guard isGitHubReady, isOnline, !isLoadingCatalog else { return }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        let accounts: [GHAccountSummaryModel]
        do {
            accounts = try await data.github.accounts()
            accountsError = nil
        } catch {
            accountsError = error.presentation
            gitHubReachability.record(error)
            return
        }
        input.accounts = accounts
        for account in accounts where account.isLoggedIn {
            do {
                input.catalogs[account.id] = try await data.catalog.catalog(accountLogin: account.account.login)
                catalogErrors[account.id] = nil
                gitHubReachability.recordSuccess()
            } catch {
                catalogErrors[account.id] = error.presentation
                gitHubReachability.record(error)
            }
        }
    }

    /// Adds a repository found by **Add repository by name…** and selects it.
    func didAddRepository(_ repo: CatalogRepoModel, accountLogin: String) {
        let key = OwnerLoginValidator.foldKey(accountLogin)
        var added = input.addedByName[key] ?? []
        added.removeAll { $0.id == repo.id }
        added.append(repo)
        input.addedByName[key] = added
        searchText = ""
        selectedRowID = SidebarGrouping.rowID(accountKey: key, repoKey: repo.id)
    }

    /// Selects the row of a vault repository, now or as soon as the vault observation lists it
    /// (a repository New Repository just staged). Clears the search so the row is visible.
    func select(repositoryID id: RepoID) {
        searchText = ""
        pendingSelection = id
        applyPendingSelection()
    }

    private func applyPendingSelection() {
        guard let id = pendingSelection else { return }
        let row = SidebarGrouping.sections(input, query: "")
            .lazy
            .flatMap(\.owners)
            .flatMap(\.repos)
            .first { $0.importedRepoID == id }
        guard let row else { return }
        pendingSelection = nil
        selectedRowID = row.id
    }

    // MARK: - Row actions

    /// Imports the repository (B2, B3, B5–B9) through its account. Needs an unlocked vault.
    func importRepository(_ repo: SidebarRepoModel) async {
        guard canImport(repo) else { return }
        await perform(on: repo) {
            let result = try await data.catalog.importRepository(try repo.ref(), accountLogin: repo.accountLogin)
            gitHubReachability.recordSuccess()
            notice = Self.importNotice(result)
        }
    }

    func canImport(_ repo: SidebarRepoModel) -> Bool {
        !repo.isImported && isUnlocked && isGitHubReady && isOnline && !isBusy(repo)
    }

    func canClone(_ repo: SidebarRepoModel) -> Bool {
        repo.isImported && repo.existsOnGitHub && isGitHubReady && isOnline && !isBusy(repo)
    }

    func canRemove(_ repo: SidebarRepoModel) -> Bool {
        repo.isImported && !isBusy(repo)
    }

    /// Clones the repository into `folder/<name>` through the account's SSH alias (§8 D3).
    func clone(_ repo: SidebarRepoModel, into folder: URL) async {
        guard canClone(repo), let id = repo.importedRepoID else { return }
        await perform(on: repo) {
            let path = try await data.cloner.clone(id, into: folder)
            notice = String(
                localized: "main.sidebar.cloned",
                defaultValue: "Cloned \(repo.fullName) to \(path.path(percentEncoded: false))"
            )
        }
    }

    /// Asks for confirmation before **Remove from vault**.
    func requestRemoval(_ repo: SidebarRepoModel) {
        guard canRemove(repo) else { return }
        pendingRemoval = repo
    }

    /// **Remove from vault**: deletes the repository with its environments and items locally.
    /// Nothing changes on GitHub.
    func confirmRemoval() async {
        guard let repo = pendingRemoval, let id = repo.importedRepoID else { return }
        pendingRemoval = nil
        await perform(on: repo) {
            try await data.catalog.removeFromVault(id)
        }
    }

    private func perform(on repo: SidebarRepoModel, _ body: () async throws -> Void) async {
        busyRepoKeys.insert(repo.repoKey)
        defer { busyRepoKeys.remove(repo.repoKey) }
        do {
            try await body()
        } catch {
            gitHubReachability.record(error)
            alert = error.presentation
        }
    }

    private static func importNotice(_ result: RepoImportResultModel) -> String {
        if result.unreadable.isEmpty {
            return String(
                localized: "main.sidebar.imported",
                defaultValue: "Imported \(result.repository.fullName): \(result.environmentCount) environments, \(result.secretCount) secrets, \(result.variableCount) variables."
            )
        }
        return String(
            localized: "main.sidebar.importedPartially",
            defaultValue: "Imported \(result.repository.fullName). \(result.unreadable.count) parts could not be read with this account's permissions."
        )
    }
}
