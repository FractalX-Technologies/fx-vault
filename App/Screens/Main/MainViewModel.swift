import AppKit
import Foundation
import Observation
import VaultCore
import VaultData

/// The two-column main window (§10.4, 1.0): it owns the sidebar tree, the detail view models,
/// the toolbar and menu commands, and the sheet router of the UI feature contract
/// (``activeSheet``).
@Observable
final class MainViewModel: LockObserving, ConnectivityObserving {
    let sidebar: SidebarViewModel
    /// The environments and destinations of the selected imported repository, nested under its
    /// sidebar row (1.0).
    private(set) var scopeList: ScopeListViewModel?
    /// The detail column of the selected imported repository.
    private(set) var detail: RepoDetailViewModel?
    /// The detail column of the selected folder (v0.7.0).
    private(set) var folderDetail: FolderDetailViewModel?
    /// The detail column of the selected destination (v0.8.0), or of the selected Key Vault of
    /// its own (1.0).
    private(set) var destinationDetail: DestinationDetailViewModel?
    /// The detail column of the selected imported organization (1.0).
    private(set) var organizationDetail: OrganizationDetailViewModel?
    /// The sheet on screen (``MainSheet``). Setting another route replaces it.
    var activeSheet: MainSheet? {
        didSet {
            if activeSheet == nil {
                presentNextPendingImport()
            }
        }
    }

    /// The Supabase and Vercel destinations 1.0 removed (migration v16), shown once after unlock.
    let retiredDestinations: RetiredDestinationsNotice

    @ObservationIgnored let app: AppViewModel
    /// The reload after the connection came back (internal so tests can await it).
    @ObservationIgnored private(set) var reconnectTask: Task<Void, Never>?

    init(app: AppViewModel) {
        self.app = app
        sidebar = SidebarViewModel(app: app)
        let destinations = app.container.data.destinations
        retiredDestinations = RetiredDestinationsNotice(
            load: { try destinations.retiredDestinationLabels() },
            dismiss: { try destinations.dismissRetiredDestinations() }
        )
        sidebar.onChange = { [weak self] in
            self?.followSelection()
        }
        app.addLockObserver(self)
        app.container.connectivity.addObserver(self)
    }

    /// Dependencies handed to every feature entry view (UI feature contract).
    var featureDependencies: FeatureDependencies {
        FeatureDependencies(container: app.container, actions: actions)
    }

    private var actions: MainActions {
        MainActions(
            present: { [weak self] sheet in self?.present(sheet) },
            refresh: { [weak self] request in self?.refresh(request) },
            beginSyncActivity: { [app] in app.beginSyncActivity() },
            addLockObserver: { [app] observer in app.addLockObserver(observer) },
            isGitHubReady: { [app] in app.ghStatus.isReady },
            select: { [weak self] id in self?.sidebar.select(repositoryID: id) },
            open: { [weak self] id, scope in self?.open(repositoryID: id, scope: scope) },
            openFolder: { [weak self] id in self?.sidebar.select(folderID: id) },
            openDestination: { [weak self] id in self?.open(destinationID: id) }
        )
    }

    /// Shows `scope` of a vault repository (v0.4.1, a linked copy's place; an imported file's
    /// first stage): selects the repository in the sidebar, then the scope once its column has
    /// the scopes.
    func open(repositoryID id: RepoID, scope: ConfigScope) {
        sidebar.select(repositoryID: id)
        if scopeList?.repositoryID == id {
            scopeList?.select(scope: scope)
        } else {
            pendingScope = (id, scope)
        }
    }

    /// A scope to select once its repository's column exists (a repository just imported from a
    /// file has no column yet).
    @ObservationIgnored private var pendingScope: (repositoryID: RepoID, scope: ConfigScope)?

    /// Shows a destination (v0.8.0, a linked copy's place): selects its repository, then the
    /// destination once its column has it; a Key Vault of its own is selected in the sidebar.
    func open(destinationID id: DestinationID) {
        guard let destination = try? app.container.data.destinations.destination(id) else { return }
        guard let repositoryID = destination.repositoryID else {
            sidebar.select(keyVaultID: id)
            return
        }
        sidebar.select(repositoryID: repositoryID)
        if scopeList?.repositoryID == repositoryID {
            scopeList?.select(destination: id)
        } else {
            pendingDestination = id
        }
    }

    /// A destination to select once the repository's column exists.
    @ObservationIgnored private var pendingDestination: DestinationID?

    // MARK: - Selection

    var selectedRepo: SidebarRepoModel? {
        sidebar.selectedRepo
    }

    /// The vault row of the selected repository, when it is imported.
    var selectedVaultRepo: RepoModel? {
        selectedRepo?.importedRepoID.flatMap(sidebar.vaultRepository)
    }

    /// Selects a repository row. The row stands for the repository scope (1.0 has no separate
    /// "Repository" row), so clicking it again from one of its environments goes back there.
    func select(repository repo: SidebarRepoModel) {
        if sidebar.selectedRowID == repo.id {
            scopeList?.selectedScopeID = ScopeListViewModel.repositoryScopeID
        } else {
            sidebar.selectedRowID = repo.id
        }
    }

    /// True for the selected repository's row while its repository scope (not an environment or
    /// a destination) is on screen.
    func isRowSelected(_ repo: SidebarRepoModel) -> Bool {
        guard sidebar.selectedRowID == repo.id else { return false }
        guard let scopeList else { return true }
        return scopeList.selectedScopeID == ScopeListViewModel.repositoryScopeID
    }

    /// The selected place as the toolbar's path: `GitHub › owner › repo › environment`, or
    /// `Folders › name`, `Azure Key Vault › name`; empty with nothing selected.
    var breadcrumb: [String] {
        if let vault = sidebar.selectedKeyVault {
            return [MainCopy.azureSection, vault.title]
        }
        if let folder = sidebar.selectedFolder {
            return [FolderCopy.sectionTitle, folder.name]
        }
        if let owner = sidebar.selectedOrganizationOwner {
            return [MainCopy.gitHubSection, owner.login]
        }
        guard let repo = selectedRepo else { return [] }
        var path = [MainCopy.gitHubSection, repo.ownerLogin, repo.name]
        if let destination = scopeList?.selectedDestination {
            path.append(destination.title)
        } else if let scope = scopeList?.selectedScope, scope.environment != nil {
            path.append(scope.title)
        }
        return path
    }

    /// Rebuilds the scopes and detail columns when the selected repository, folder, organization
    /// or Key Vault changes (or the repository or organization becomes imported, or is removed).
    private func followSelection() {
        if let id = sidebar.selectedKeyVaultID {
            detail = nil
            scopeList = nil
            folderDetail = nil
            organizationDetail = nil
            guard destinationDetail?.destinationID != id, let vault = sidebar.keyVault(id) else { return }
            destinationDetail = DestinationDetailViewModel(destination: vault, dependencies: featureDependencies) { [weak sidebar] in
                sidebar?.keyVault(id)
            }
            return
        }
        // A Key Vault's detail has no repository column to clear it with below.
        if destinationDetail?.repositoryID == nil {
            destinationDetail = nil
        }
        if let owner = sidebar.selectedOrganizationOwner {
            detail = nil
            scopeList = nil
            destinationDetail = nil
            folderDetail = nil
            guard let id = owner.organization?.id else {
                organizationDetail = nil
                return
            }
            guard organizationDetail?.organizationID != id else { return }
            organizationDetail = OrganizationDetailViewModel(organizationID: id, dependencies: featureDependencies) { [weak sidebar] in
                sidebar?.vaultOrganization(id)
            }
            return
        }
        organizationDetail = nil
        if let folderID = sidebar.selectedFolderID {
            guard folderDetail?.folderID != folderID else { return }
            detail = nil
            scopeList = nil
            folderDetail = FolderDetailViewModel(folderID: folderID, dependencies: featureDependencies) { [weak sidebar] in
                sidebar?.folder(folderID)
            }
            return
        }
        folderDetail = nil
        let repoID = selectedRepo?.importedRepoID
        guard scopeList?.repositoryID != repoID else { return }
        detail = nil
        scopeList = nil
        destinationDetail = nil
        guard let repoID else { return }
        let dependencies = featureDependencies
        let sidebar = sidebar
        let scopes = ScopeListViewModel(repositoryID: repoID, dependencies: dependencies) {
            sidebar.vaultRepository(repoID)
        }
        let detail = RepoDetailViewModel(
            repositoryID: repoID,
            dependencies: dependencies,
            repository: { sidebar.vaultRepository(repoID) },
            scopeSummary: { [weak scopes] scope in scopes?.scopes.first { $0.scope == scope } }
        )
        scopes.onSelectionChange = { [weak self, weak scopes, weak detail] in
            guard let scopes else { return }
            self?.followScopeSelection(scopes)
            guard let scope = scopes.selectedScope?.scope else { return }
            detail?.select(scope: scope)
        }
        scopeList = scopes
        self.detail = detail
        detail.checkDriftOnOpen()
        if let pendingDestination {
            self.pendingDestination = nil
            scopes.select(destination: pendingDestination)
        }
        if let pendingScope, pendingScope.repositoryID == repoID {
            self.pendingScope = nil
            scopes.select(scope: pendingScope.scope)
        }
    }

    /// The detail follows the tree's selection: a destination's detail or the repository detail of
    /// the selected scope (v0.8.0).
    private func followScopeSelection(_ scopes: ScopeListViewModel) {
        if let destination = scopes.selectedDestination {
            guard destinationDetail?.destinationID != destination.id else { return }
            let id = destination.id
            destinationDetail = DestinationDetailViewModel(destination: destination, dependencies: featureDependencies) { [weak scopes] in
                scopes?.destination(id)
            }
            return
        }
        destinationDetail = nil
    }

    // MARK: - Sheets

    func present(_ sheet: MainSheet) {
        guard app.phase == .unlocked else { return }
        guard isOnline || !sheet.needsInternet else { return }
        activeSheet = sheet
    }

    /// Opens the share import sheet for the oldest `.fxvault` file waiting (§10 Scenes), unless
    /// another sheet is on screen (it follows when that one closes).
    func presentNextPendingImport() {
        guard activeSheet == nil, let url = app.takeNextPendingImport() else { return }
        activeSheet = .shareImport(ShareImportContext(fileURL: url))
    }

    /// The share selection for the current column selection: the environment, the repository,
    /// or the folder (v0.7.0).
    var currentShareSelection: ShareSelectionModel? {
        if let folder = sidebar.selectedFolder {
            return folder.itemCount > 0 ? .folder(folder.id) : nil
        }
        guard selectedVaultRepo != nil, let scopeList, let scope = scopeList.selectedScope else { return nil }
        return scopeList.shareSelection(for: scope)
    }

    // MARK: - Refresh

    func refresh(_ request: MainRefreshRequest) {
        switch request {
        case .catalog:
            Task { await sidebar.reload() }
        case .repository(let id):
            let catalog = app.container.data.catalog
            Task {
                do {
                    try await catalog.refreshRepository(id)
                } catch {
                    AppLog.ui.error("Repository refresh failed")
                }
            }
        case .drift(let id):
            guard let detail, detail.repositoryID == id else { return }
            Task { await detail.refreshDrift() }
        }
    }

    // MARK: - Toolbar and commands (§10 Toolbar)

    var pendingChangeCount: Int {
        app.pendingChangeCount
    }

    var isSyncing: Bool {
        app.isSyncing
    }

    private var isUnlocked: Bool {
        app.phase == .unlocked
    }

    /// Disabled at 0, while locked, while a sync runs (§10 Toolbar) and while offline.
    var canSync: Bool {
        pendingChangeCount > 0 && isUnlocked && !isSyncing && app.ghStatus.isReady && isOnline
    }

    func sync() {
        guard canSync else { return }
        present(.sync(SyncContext(repositoryIDs: nil)))
    }

    /// Needs gh and the internet (owners, templates and the name check call GitHub).
    var canCreateRepository: Bool {
        isUnlocked && app.ghStatus.isReady && isOnline
    }

    /// New Repository (⌘N), with the selected account and owner preselected.
    func newRepository() {
        guard canCreateRepository else { return }
        present(.createRepository(CreateRepoContext(
            accountLogin: selectedRepo?.accountLogin,
            ownerLogin: selectedRepo?.ownerLogin
        )))
    }

    /// Import .env (⇧⌘I) needs a selected scope whose items can change, a folder or a
    /// destination.
    var canImportEnv: Bool {
        isUnlocked && (folderDetail?.canEdit == true || destinationDetail?.canEdit == true
            || (scopeList?.selectedScope != nil && detail?.canEdit == true))
    }

    func importEnv() {
        guard canImportEnv else { return }
        if let folderDetail {
            present(.envImport(EnvImportContext(place: .folder(folderDetail.folderID))))
            return
        }
        if let destinationDetail {
            present(.envImport(EnvImportContext(place: .destination(destinationDetail.destinationID))))
            return
        }
        guard let repo = selectedVaultRepo, let scope = scopeList?.selectedScope else { return }
        present(.envImport(EnvImportContext(repositoryID: repo.id, scope: scope.scope, fileURL: nil)))
    }

    /// New Folder… (⇧⌘N, v0.7.0).
    func newFolder() {
        guard isUnlocked else { return }
        present(.folderName(FolderNameContext(mode: .create(itemIDs: []))))
    }

    /// File › Share Project… (v0.9.0): the selected scope or folder, or the selected repository.
    var canShareProject: Bool {
        isUnlocked && projectShareSelection != nil
    }

    func shareProject() {
        guard canShareProject, let selection = projectShareSelection else { return }
        present(.shareExport(ShareExportContext(selection: selection)))
    }

    private var projectShareSelection: ShareSelectionModel? {
        currentShareSelection ?? selectedVaultRepo.map { .repository($0.id) }
    }

    func addRepositoryByName(accountLogin: String) {
        guard sidebar.canAddByName else { return }
        present(.addRepositoryByName(AddRepositoryContext(accountLogin: accountLogin)))
    }

    func lock() {
        app.lock(trigger: .manual)
    }

    /// Shows the "recovery key not confirmed" banner (the vault locked during onboarding or a
    /// recovery reset before the key was saved).
    var showsRecoveryKeyReminder: Bool {
        app.container.preferences.isRecoveryKeyConfirmationPending
    }

    // MARK: - Clone

    /// The folder new clones go to, or nil until one is chosen (Preferences › General).
    var cloneFolderURL: URL? {
        app.container.preferences.cloneFolderURL
    }

    func setCloneFolder(_ url: URL) {
        app.container.preferences.setCloneFolder(url)
    }

    // MARK: - Connectivity (v0.2.0)

    var isOnline: Bool {
        app.container.connectivity.isOnline
    }

    /// The banner at the top of the main window: offline first, then GitHub not responding.
    var connectivityBanner: ConnectivityBannerModel? {
        if !isOnline {
            return .offline
        }
        let github = app.container.gitHubReachability
        return github.isResponding ? nil : .gitHubNotResponding(isRetrying: github.isRetrying)
    }

    /// The `.help` of a gh-backed action: why it is disabled while offline, `help` otherwise.
    func networkHelp(_ help: String) -> String {
        isOnline ? help : ConnectivityCopy.offlineHelp
    }

    /// **Retry** on the "GitHub isn't responding" banner: the calls the window already makes
    /// (the repository lists and the open repository's drift check), which report back to
    /// `GitHubReachability`.
    func retryGitHub() async {
        guard isOnline else { return }
        await app.container.gitHubReachability.retry { [sidebar, detail] in
            await sidebar.reload()
            await detail?.refreshDrift()
        }
    }

    /// The connection came back: the GitHub state starts over, the repository lists load again
    /// if they could not load before, and the open repository's drift check runs again (a full
    /// re-list only if the last one failed or was skipped offline). A reconnect replaces the
    /// previous one, so a flapping connection never runs them side by side.
    func connectivityDidChange(isOnline: Bool) {
        guard isOnline else { return }
        app.container.gitHubReachability.reset()
        reconnectTask?.cancel()
        reconnectTask = nil
        guard isUnlocked else { return }
        let sidebar = sidebar
        let detail = detail
        reconnectTask = Task {
            if sidebar.needsReload {
                await sidebar.reload()
            }
            guard !Task.isCancelled else { return }
            await detail?.checkDriftAfterReconnect()
        }
    }

    // MARK: - LockObserving

    func vaultDidLock() {
        reconnectTask?.cancel()
        reconnectTask = nil
        activeSheet = nil
    }
}
