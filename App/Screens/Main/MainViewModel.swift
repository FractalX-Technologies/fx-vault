import AppKit
import Foundation
import Observation
import VaultCore
import VaultData

/// The three-column main window (§10.4): it owns the column view models, the toolbar and menu
/// commands, and the sheet router of the UI feature contract (``activeSheet``).
@Observable
final class MainViewModel: LockObserving {
    let sidebar: SidebarViewModel
    /// The scopes column of the selected imported repository.
    private(set) var scopeList: ScopeListViewModel?
    /// The detail column of the selected imported repository.
    private(set) var detail: RepoDetailViewModel?
    /// The sheet on screen (``MainSheet``). Setting another route replaces it.
    var activeSheet: MainSheet? {
        didSet {
            if activeSheet == nil {
                presentNextPendingImport()
            }
        }
    }

    @ObservationIgnored let app: AppViewModel

    init(app: AppViewModel) {
        self.app = app
        sidebar = SidebarViewModel(app: app)
        sidebar.onChange = { [weak self] in
            self?.followSelection()
        }
        app.addLockObserver(self)
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
            select: { [weak self] id in self?.sidebar.select(repositoryID: id) }
        )
    }

    // MARK: - Selection

    var selectedRepo: SidebarRepoModel? {
        sidebar.selectedRepo
    }

    /// The vault row of the selected repository, when it is imported.
    var selectedVaultRepo: RepoModel? {
        selectedRepo?.importedRepoID.flatMap(sidebar.vaultRepository)
    }

    /// Rebuilds the scopes and detail columns when the selected repository changes (or becomes
    /// imported, or is removed).
    private func followSelection() {
        let repoID = selectedRepo?.importedRepoID
        guard scopeList?.repositoryID != repoID else { return }
        detail = nil
        scopeList = nil
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
        scopes.onSelectionChange = { [weak scopes, weak detail] in
            guard let scope = scopes?.selectedScope?.scope else { return }
            detail?.select(scope: scope)
        }
        scopeList = scopes
        self.detail = detail
        detail.checkDriftOnOpen()
    }

    // MARK: - Sheets

    func present(_ sheet: MainSheet) {
        guard app.phase == .unlocked else { return }
        activeSheet = sheet
    }

    /// Opens the share import sheet for the oldest `.fxvault` file waiting (§10 Scenes), unless
    /// another sheet is on screen (it follows when that one closes).
    func presentNextPendingImport() {
        guard activeSheet == nil, let url = app.takeNextPendingImport() else { return }
        activeSheet = .shareImport(ShareImportContext(fileURL: url))
    }

    /// The share selection for the current column selection: the environment, or the
    /// repository.
    var currentShareSelection: ShareSelectionModel? {
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

    /// Disabled at 0, while locked and while a sync runs (§10 Toolbar).
    var canSync: Bool {
        pendingChangeCount > 0 && isUnlocked && !isSyncing && app.ghStatus.isReady
    }

    func sync() {
        guard canSync else { return }
        present(.sync(SyncContext(repositoryIDs: nil)))
    }

    var canCreateRepository: Bool {
        isUnlocked && app.ghStatus.isReady
    }

    /// New Repository (⌘N), with the selected account and owner preselected.
    func newRepository() {
        guard canCreateRepository else { return }
        present(.createRepository(CreateRepoContext(
            accountLogin: selectedRepo?.accountLogin,
            ownerLogin: selectedRepo?.ownerLogin
        )))
    }

    /// Import .env (⇧⌘I) needs a selected scope whose items can change.
    var canImportEnv: Bool {
        isUnlocked && scopeList?.selectedScope != nil && detail?.canEdit == true
    }

    func importEnv() {
        guard canImportEnv, let repo = selectedVaultRepo, let scope = scopeList?.selectedScope else { return }
        present(.envImport(EnvImportContext(repositoryID: repo.id, scope: scope.scope, fileURL: nil)))
    }

    var canShareFile: Bool {
        isUnlocked && currentShareSelection != nil
    }

    /// Share › File… for the selected scope.
    func shareFile() {
        guard canShareFile, let selection = currentShareSelection else { return }
        present(.shareExport(ShareExportContext(selection: selection)))
    }

    /// Share › Nearby… (the sheet asks what to send when nothing is selected).
    func shareNearby() {
        guard isUnlocked else { return }
        present(.nearbySend(NearbySendContext(selection: currentShareSelection)))
    }

    /// Share › Receive Nearby….
    func receiveNearby() {
        guard isUnlocked else { return }
        present(.nearbyReceive(NearbyReceiveContext()))
    }

    func addRepositoryByName(accountLogin: String) {
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

    // MARK: - LockObserving

    func vaultDidLock() {
        activeSheet = nil
    }
}
