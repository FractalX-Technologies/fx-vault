import Foundation
import GitHubKit
import Observation
import VaultCore
import VaultData

/// Column 1 (§10; boards Main2-Home, Main2-Expanded): one node per owner across the gh accounts
/// (an organization node is its place), repositories, Key Vaults and folders, with search (⌘F),
/// Import, Clone, Remove from vault and Add repository by name.
///
/// - Vault repositories and organizations are observed (`ConfigRepository.observeRepositories()`,
///   `OrganizationRepository.observeOrganizations()`), so imports, removals and created
///   repositories appear at once and work without gh.
/// - One place is selected at a time: a repository row, a folder, an organization row or a Key
///   Vault of its own (observed with `observeDestinations(repositoryID: nil)`).
/// - Accounts and catalogs come from gh (`GitHubEnvironmentRepository.accounts()`,
///   `RepoCatalogRepository.catalog(accountLogin:)`) and load when gh is ready.
@Observable
final class SidebarViewModel {
    var searchText = ""
    /// Bumped by ⌘F; the search field takes the focus when it changes.
    private(set) var searchFocusRequest = 0
    /// A ⌘F the search field has not taken yet: the sidebar was hidden, so the field takes the
    /// focus when it appears.
    private(set) var isSearchFocusPending = false
    var selectedRowID: SidebarRepoModel.ID? {
        didSet {
            guard selectedRowID != oldValue else { return }
            if let selectedRowID {
                clearSelection(except: .repository)
                expandOwner(ofRow: selectedRowID)
            }
            onChange?()
        }
    }
    /// The owner nodes showing their repositories; collapsed by default, and a selection
    /// expands the nodes above it.
    private(set) var expandedOwnerIDs: Set<SidebarOwnerModel.ID> = []
    /// The owner nodes whose "Show N more" was clicked.
    private(set) var fullyShownOwnerIDs: Set<SidebarOwnerModel.ID> = []
    /// The folders (v0.7.0), in the user's order.
    private(set) var folders: [FolderModel] = []
    /// The selected folder: selecting one clears the repository selection, and back.
    var selectedFolderID: FolderID? {
        didSet {
            guard selectedFolderID != oldValue else { return }
            if selectedFolderID != nil {
                clearSelection(except: .folder)
            }
            onChange?()
        }
    }
    /// The owner group whose organization row is selected (1.0).
    var selectedOrganizationOwnerID: SidebarOwnerModel.ID? {
        didSet {
            guard selectedOrganizationOwnerID != oldValue else { return }
            if let selectedOrganizationOwnerID {
                clearSelection(except: .organization)
                expandedOwnerIDs.insert(selectedOrganizationOwnerID)
            }
            onChange?()
        }
    }
    /// The Azure Key Vaults of their own (1.0), listed under AZURE KEY VAULT.
    private(set) var keyVaults: [DestinationModel] = []
    /// The selected Key Vault of its own.
    var selectedKeyVaultID: DestinationID? {
        didSet {
            guard selectedKeyVaultID != oldValue else { return }
            if selectedKeyVaultID != nil {
                clearSelection(except: .keyVault)
            }
            onChange?()
        }
    }
    /// The Key Vault of its own waiting for the "Remove this destination?" confirmation.
    var pendingKeyVaultRemoval: DestinationModel?
    /// The organization waiting for the "Remove from vault?" confirmation.
    var pendingOrganizationRemoval: OrganizationModel?
    /// The folder waiting for the "Delete the folder?" confirmation.
    var pendingFolderDeletion: FolderModel?
    private(set) var input = SidebarInputModel()
    private(set) var isLoadingCatalog = false
    /// Why accounts could not be listed at all; nil when they were (or gh is not ready).
    private(set) var accountsError: ErrorPresentationModel?
    /// Per-account catalog failures, by account fold key.
    private(set) var catalogErrors: [String: ErrorPresentationModel] = [:]
    /// The organization access read after the catalogs (``reload()``), so ``needsReload`` is not
    /// held up by it.
    @ObservationIgnored private(set) var accessTask: Task<Void, Never>?
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
        observeFolders()
        observeOrganizations()
        observeKeyVaults()
    }

    private var data: VaultDataComponents {
        app.container.data
    }

    // MARK: - Content

    /// The owner nodes under GitHub, filtered by the search.
    var owners: [SidebarOwnerModel] {
        SidebarGrouping.owners(input, query: searchText)
    }

    /// Every owner node, whatever the search.
    private var allOwners: [SidebarOwnerModel] {
        SidebarGrouping.owners(input, query: "")
    }

    /// The selected row (searched in the unfiltered tree, so a search never loses it).
    var selectedRepo: SidebarRepoModel? {
        guard let selectedRowID else { return nil }
        return allOwners.lazy.flatMap(\.repos).first { $0.id == selectedRowID }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A search shows every owner open.
    func isExpanded(_ owner: SidebarOwnerModel) -> Bool {
        isSearching || expandedOwnerIDs.contains(owner.id)
    }

    func toggle(_ owner: SidebarOwnerModel) {
        if expandedOwnerIDs.contains(owner.id) {
            expandedOwnerIDs.remove(owner.id)
        } else {
            expandedOwnerIDs.insert(owner.id)
        }
    }

    /// The owner's repositories on screen, and how many "Show N more" holds.
    func repoList(of owner: SidebarOwnerModel) -> SidebarRepoListModel {
        SidebarGrouping.repoList(
            of: owner,
            selectedRowID: selectedRowID,
            showsAll: isSearching || fullyShownOwnerIDs.contains(owner.id)
        )
    }

    func showAllRepositories(of owner: SidebarOwnerModel) {
        fullyShownOwnerIDs.insert(owner.id)
    }

    /// ⌘F: puts the focus in the search field.
    func focusSearch() {
        isSearchFocusPending = true
        searchFocusRequest += 1
    }

    /// The search field took the focus.
    func didFocusSearch() {
        isSearchFocusPending = false
    }

    /// The search field could not take the focus in time (the window not key, a slow slide): the
    /// request is dropped so it does not grab the focus the next time the sidebar shows.
    func cancelSearchFocus() {
        isSearchFocusPending = false
    }

    private func expandOwner(ofRow id: SidebarRepoModel.ID) {
        // A row id is `owner/name` folded; the owner node's id is the folded owner.
        guard let owner = id.split(separator: "/").first else { return }
        expandedOwnerIDs.insert(String(owner))
    }

    /// The vault row of an imported repository.
    func vaultRepository(_ id: RepoID) -> RepoModel? {
        input.vaultRepos.first { $0.id == id }
    }

    /// The selected organization node (searched in the unfiltered tree).
    var selectedOrganizationOwner: SidebarOwnerModel? {
        guard let selectedOrganizationOwnerID else { return nil }
        return allOwners.first { $0.id == selectedOrganizationOwnerID }
    }

    /// The vault row of an imported organization.
    func vaultOrganization(_ id: OrganizationID) -> OrganizationModel? {
        input.vaultOrganizations.first { $0.id == id }
    }

    /// The names of the repositories listed under an imported organization (Selected access
    /// offers them).
    func organizationRepositoryNames(_ id: OrganizationID) -> [String] {
        allOwners.first { $0.organization?.id == id }?.repos.map(\.name) ?? []
    }

    private enum SelectionKind {
        case repository, folder, organization, keyVault
    }

    /// Clears the other selections (each `didSet` reports the change once).
    private func clearSelection(except kept: SelectionKind) {
        if kept != .repository, selectedRowID != nil { selectedRowID = nil }
        if kept != .folder, selectedFolderID != nil { selectedFolderID = nil }
        if kept != .organization, selectedOrganizationOwnerID != nil { selectedOrganizationOwnerID = nil }
        if kept != .keyVault, selectedKeyVaultID != nil { selectedKeyVaultID = nil }
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

    /// The first account whose repositories could not be listed (the footer shows it).
    var catalogError: ErrorPresentationModel? {
        catalogErrors.sorted { $0.key < $1.key }.first?.value
    }

    func isBusy(_ repo: SidebarRepoModel) -> Bool {
        busyRepoKeys.contains(repo.repoKey)
    }

    func isBusy(_ owner: SidebarOwnerModel) -> Bool {
        busyRepoKeys.contains(Self.busyKey(owner))
    }

    /// Organizations share ``busyRepoKeys``; `org|` keeps them apart from `owner/name` keys.
    private static func busyKey(_ owner: SidebarOwnerModel) -> String {
        "org|\(OwnerLoginValidator.foldKey(owner.login))"
    }

    // MARK: - Folders (v0.7.0)

    /// The folders whose name matches the search.
    var visibleFolders: [FolderModel] {
        folders.filter { matchesSearch($0.name) }
    }

    /// Folders and Key Vaults match the search by name; an empty search matches everything.
    private func matchesSearch(_ name: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || name.localizedCaseInsensitiveContains(query)
    }

    func folder(_ id: FolderID) -> FolderModel? {
        folders.first { $0.id == id }
    }

    var selectedFolder: FolderModel? {
        selectedFolderID.flatMap(folder)
    }

    /// Selects a folder (a linked copy's place, a new folder). Clears the search.
    func select(folderID id: FolderID) {
        searchText = ""
        selectedFolderID = id
    }

    /// "Delete Folder": removes it with its items; copies in repositories stay.
    func confirmFolderDeletion() {
        guard let folder = pendingFolderDeletion else { return }
        pendingFolderDeletion = nil
        do {
            try data.folders.deleteFolder(folder.id)
        } catch {
            alert = error.presentation
        }
    }

    /// Puts `moved` right before `target` (a folder dragged onto another one).
    func moveFolder(_ moved: FolderID, before target: FolderID) {
        var order = folders.map(\.id)
        guard moved != target, let from = order.firstIndex(of: moved) else { return }
        order.remove(at: from)
        guard let to = order.firstIndex(of: target) else { return }
        order.insert(moved, at: to)
        do {
            try data.folders.reorderFolders(order)
        } catch {
            alert = error.presentation
        }
    }

    private func observeFolders() {
        let stream = data.folders.observeFolders()
        tasks.set("folders", Task { [weak self] in
            do {
                for try await folders in stream {
                    guard let self else { return }
                    self.folders = folders
                    if let id = selectedFolderID, !folders.contains(where: { $0.id == id }) {
                        selectedFolderID = nil
                    }
                }
            } catch {
                AppLog.ui.error("Folder observation ended")
            }
        })
    }

    // MARK: - Azure Key Vault (1.0)

    /// The Key Vaults of their own whose name matches the search.
    var visibleKeyVaults: [DestinationModel] {
        keyVaults.filter { matchesSearch($0.title) }
    }

    func keyVault(_ id: DestinationID) -> DestinationModel? {
        keyVaults.first { $0.id == id }
    }

    var selectedKeyVault: DestinationModel? {
        selectedKeyVaultID.flatMap(keyVault)
    }

    /// Selects a Key Vault of its own (a linked copy's place). Clears the search.
    func select(keyVaultID id: DestinationID) {
        searchText = ""
        selectedKeyVaultID = id
    }

    /// Removes the vault and its items from FX Vault; nothing changes in Azure.
    func confirmKeyVaultRemoval() {
        guard let vault = pendingKeyVaultRemoval else { return }
        pendingKeyVaultRemoval = nil
        do {
            try data.destinations.deleteDestination(vault.id)
        } catch {
            alert = error.presentation
        }
    }

    private func observeKeyVaults() {
        let stream = data.destinations.observeDestinations(repositoryID: nil)
        tasks.set("keyVaults", Task { [weak self] in
            do {
                for try await vaults in stream {
                    guard let self else { return }
                    keyVaults = vaults
                    if let id = selectedKeyVaultID, !vaults.contains(where: { $0.id == id }) {
                        selectedKeyVaultID = nil
                    }
                    // A vault selected before it was listed (just imported) gets its detail now.
                    onChange?()
                }
            } catch {
                AppLog.ui.error("Key Vault observation ended")
            }
        })
    }

    // MARK: - Organizations (1.0)

    /// Selects an organization row.
    func select(organization owner: SidebarOwnerModel) {
        selectedOrganizationOwnerID = owner.id
    }

    func canImportOrganization(_ owner: SidebarOwnerModel) -> Bool {
        owner.isOrganization && owner.organization == nil && isUnlocked && isGitHubReady && isOnline && !isBusy(owner)
    }

    /// Imports the organization's secrets (names) and variables (B12, B13) through the account
    /// that lists it. Needs an unlocked vault.
    func importOrganization(_ owner: SidebarOwnerModel) async {
        guard canImportOrganization(owner) else { return }
        await perform(busyKey: Self.busyKey(owner)) {
            let result = try await data.organizations.importOrganization(login: owner.login, accountLogin: owner.accountLogin)
            gitHubReachability.recordSuccess()
            notice = String(
                localized: "main.sidebar.organizationImported",
                defaultValue: "Imported \(owner.login): \(result.organization.secretCount) secrets, \(result.organization.variableCount) variables."
            )
        }
    }

    /// Asks for confirmation before **Remove from vault** of an organization.
    func requestRemoval(_ organization: OrganizationModel) {
        pendingOrganizationRemoval = organization
    }

    /// Deletes the organization's secrets and variables locally. Nothing changes on GitHub.
    func confirmOrganizationRemoval() async {
        guard let organization = pendingOrganizationRemoval else { return }
        pendingOrganizationRemoval = nil
        do {
            try await data.organizations.removeOrganization(organization.id)
        } catch {
            alert = error.presentation
        }
    }

    private func observeOrganizations() {
        let stream = data.organizations.observeOrganizations()
        tasks.set("organizations", Task { [weak self] in
            do {
                for try await organizations in stream {
                    guard let self else { return }
                    input.vaultOrganizations = organizations
                    onChange?()
                }
            } catch {
                AppLog.ui.error("Organization observation ended")
            }
        })
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

    /// Lists the gh accounts and each logged-in account's catalog, then reads their organization
    /// access in the background (``accessTask``). Does nothing until gh is ready or while
    /// offline. Catalog results feed `GitHubReachability`.
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
        loadOrganizationAccess(accounts.filter(\.isLoggedIn).map(\.account.login))
    }

    /// Which organizations need `admin:org` or SSO (the owner sublines). The tree does not wait for
    /// it; a failure leaves the sublines out (Settings › Accounts explains it).
    private func loadOrganizationAccess(_ logins: [String]) {
        let github = data.github
        accessTask?.cancel()
        accessTask = Task { [weak self] in
            for login in logins {
                guard let access = try? await github.organizationAccess(accountLogin: login) else { continue }
                guard let self, !Task.isCancelled else { return }
                input.organizationAccess[OwnerLoginValidator.foldKey(login)] = access
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
        selectedRowID = repo.id
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
        let row = allOwners.lazy.flatMap(\.repos).first { $0.importedRepoID == id }
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
        await perform(busyKey: repo.repoKey, body)
    }

    private func perform(busyKey: String, _ body: () async throws -> Void) async {
        busyRepoKeys.insert(busyKey)
        defer { busyRepoKeys.remove(busyKey) }
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
