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
    /// Notes or Table, for every place (1.0 B9); Notes at each launch. Changed through
    /// ``show(_:)``, which asks before Table drops an edit of the notes.
    private(set) var placeViewMode: PlaceViewMode = .notes
    /// "Discard N unsaved changes?" (1.0 N2): another place, scope or Table waits for it while
    /// the place on screen keeps its edit.
    private(set) var discardRequest: NotesDiscardRequestModel?
    /// The sheet on screen (``MainSheet``). Setting another route replaces it.
    var activeSheet: MainSheet? {
        didSet {
            if activeSheet == nil {
                presentNextPendingImport()
                presentRequestedSyncReview(after: oldValue)
            } else {
                // A menu command or an opened .fxvault file can bring a sheet over the palette; it
                // would come back stale when the sheet goes.
                jumpPalette = nil
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

    // MARK: - Leaving an edit of the notes (1.0 N2)

    /// What the sidebar and the scopes selected when the detail last followed them: Keep Editing
    /// goes back to it.
    @ObservationIgnored private var shownSelection = PlaceSelectionModel()
    /// What runs after Discard: following the new selection, Table.
    @ObservationIgnored private var discardResumes: [() -> Void] = []
    @ObservationIgnored private var isRestoringSelection = false

    /// The edit of the place on screen.
    var openNotesEdit: NotesEditSession? {
        destinationDetail?.notesEdit ?? folderDetail?.notesEdit ?? detail?.notesEdit
    }

    private var currentSelection: PlaceSelectionModel {
        PlaceSelectionModel(
            rowID: sidebar.selectedRowID,
            folderID: sidebar.selectedFolderID,
            organizationOwnerID: sidebar.selectedOrganizationOwnerID,
            keyVaultID: sidebar.selectedKeyVaultID,
            scopeID: scopeList?.selectedScopeID
        )
    }

    /// Notes or Table (the header's picker, ⌘K): Table asks first while the notes have unsaved
    /// edits, since it drops them.
    func show(_ mode: PlaceViewMode) {
        guard mode != placeViewMode else { return }
        guard mode == .table, let edit = openNotesEdit, edit.changeCount > 0 else {
            placeViewMode = mode
            return
        }
        ask(toDiscard: edit) { [weak self] in
            self?.placeViewMode = .table
        }
    }

    /// True when the detail must not follow the selection yet: it is going back after Keep
    /// Editing, or it would drop an edit with unsaved changes (then "Discard…?" asks first and
    /// `resume` follows it after Discard). Lock and closing the window discard without asking.
    private func holdsForNotesEdit(resume: @escaping () -> Void) -> Bool {
        if isRestoringSelection {
            return true
        }
        let selection = currentSelection
        guard selection != shownSelection else { return false }
        if discardRequest != nil {
            return true
        }
        guard let edit = openNotesEdit, edit.changeCount > 0 else {
            shownSelection = selection
            return false
        }
        ask(toDiscard: edit, then: resume)
        return true
    }

    private func ask(toDiscard edit: NotesEditSession, then resume: @escaping () -> Void) {
        if discardRequest == nil {
            discardRequest = NotesDiscardRequestModel(count: edit.changeCount)
        }
        discardResumes.append(resume)
    }

    /// Discard: the edit ends and its values are wiped, then the selection or Table goes ahead.
    func discardNotesEdit() {
        guard discardRequest != nil else { return }
        discardRequest = nil
        let resumes = discardResumes
        discardResumes = []
        openNotesEdit?.finish()
        for resume in resumes {
            resume()
        }
    }

    /// Keep Editing (or Esc): the sidebar and the scopes go back to the place being edited, and
    /// nothing asked for meanwhile (a ⌘K row, a scope or destination to open) is left pending.
    func keepEditingNotes() {
        guard discardRequest != nil else { return }
        discardRequest = nil
        discardResumes = []
        pendingRow = nil
        pendingScope = nil
        pendingDestination = nil
        let selection = shownSelection
        isRestoringSelection = true
        defer { isRestoringSelection = false }
        if let id = selection.keyVaultID {
            sidebar.selectedKeyVaultID = id
        } else if let id = selection.organizationOwnerID {
            sidebar.selectedOrganizationOwnerID = id
        } else if let id = selection.folderID {
            sidebar.selectedFolderID = id
        } else if let id = selection.rowID {
            sidebar.selectedRowID = id
        } else {
            sidebar.selectedRowID = nil
            sidebar.selectedFolderID = nil
            sidebar.selectedOrganizationOwnerID = nil
            sidebar.selectedKeyVaultID = nil
        }
        scopeList?.selectedScopeID = selection.scopeID
    }

    // MARK: - Revealed values

    /// A secret shows in the open place (notes or table), or its notes are edited (a value set
    /// there shows in its token): the window stays out of screen capture and the toolbar says so
    /// (board Place-Reveal).
    var isShowingRevealedValue: Bool {
        [detail?.values, folderDetail?.values, destinationDetail?.values, organizationDetail?.values]
            .contains { $0?.isShowingRevealedValue == true }
            || [detail?.notesEdit, folderDetail?.notesEdit, destinationDetail?.notesEdit].contains { $0 != nil }
    }

    /// Masks every revealed value of the open places (FX Vault resigned active).
    func remaskRevealedValues() {
        detail?.remaskAll()
        folderDetail?.remaskAll()
        destinationDetail?.remaskAll()
        organizationDetail?.remaskAll()
    }

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
        select(repositoryRow: repo.id)
    }

    private func select(repositoryRow id: SidebarRepoModel.ID) {
        if sidebar.selectedRowID == id {
            scopeList?.selectedScopeID = ScopeListViewModel.repositoryScopeID
        } else {
            sidebar.selectedRowID = id
        }
    }

    /// True for the selected repository's row while its repository scope (not an environment or
    /// a destination) is on screen.
    func isRowSelected(_ repo: SidebarRepoModel) -> Bool {
        guard sidebar.selectedRowID == repo.id else { return false }
        guard let scopeList else { return true }
        return scopeList.selectedScopeID == ScopeListViewModel.repositoryScopeID
    }

    /// The selected place as the toolbar's path, named like its sidebar section:
    /// `GitHub › owner › repo › environment`, `Azure › vault` or `Folders › parent › name`; empty with
    /// nothing selected.
    var breadcrumb: [String] {
        if let vault = sidebar.selectedKeyVault {
            // The sidebar's tree: a vault without a saved subscription sits directly under Azure.
            return [SidebarCopy.azureSection] + [vault.subscription?.name, vault.title].compactMap(\.self)
        }
        if let folder = sidebar.selectedFolder {
            return [FolderCopy.sectionTitle] + sidebar.folders.path(of: folder.id)
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
        guard !holdsForNotesEdit(resume: { [weak self] in self?.followSelection() }) else { return }
        dropPendingRowElsewhere()
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
            organizationDetail = OrganizationDetailViewModel(
                organizationID: id,
                dependencies: featureDependencies,
                organization: { [weak sidebar] in sidebar?.vaultOrganization(id) },
                repositoryNames: { [weak sidebar] in sidebar?.organizationRepositoryNames(id) ?? [] }
            )
            return
        }
        organizationDetail = nil
        if let folderID = sidebar.selectedFolderID {
            guard folderDetail?.folderID != folderID else { return }
            detail = nil
            scopeList = nil
            folderDetail = FolderDetailViewModel(folderID: folderID, dependencies: featureDependencies) { [weak sidebar] in
                sidebar?.folders ?? []
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
            let resume: () -> Void = { [weak scopes] in scopes?.onSelectionChange?() }
            guard self?.holdsForNotesEdit(resume: resume) != true else { return }
            self?.followScopeSelection(scopes)
            self?.dropPendingRowElsewhere()
            guard let scope = scopes.selectedScope?.scope else { return }
            detail?.select(scope: scope)
            self?.selectPendingRow()
        }
        scopeList = scopes
        // A new list starts at its repository scope without calling `onSelectionChange`.
        shownSelection = currentSelection
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

    /// Opens the Sync review the menu bar asked for (``AppViewModel/requestSyncReview()``),
    /// unless another sheet is on screen (it follows when that one closes). Asked while the Sync
    /// sheet is up (`closedSheet` when it just closed), the request was for that sheet: it ends.
    func presentRequestedSyncReview(after closedSheet: MainSheet? = nil) {
        if case .sync? = closedSheet ?? activeSheet {
            _ = app.takeSyncReviewRequest()
            return
        }
        guard activeSheet == nil, app.takeSyncReviewRequest() else { return }
        sync()
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
        app.hasChangesToSync && isUnlocked && app.ghStatus.isReady && isOnline
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

    /// New Repository… on an owner's context menu (1.0 D6c2), with that owner preselected.
    func newRepository(in owner: SidebarOwnerModel) {
        guard canCreateRepository else { return }
        present(.createRepository(CreateRepoContext(accountLogin: owner.accountLogin, ownerLogin: owner.login)))
    }

    /// Import .env (⇧⌘I) needs a selected scope whose items can change, a folder or a
    /// destination, none of them with its notes being edited.
    var canImportEnv: Bool {
        isUnlocked && (folderDetail?.acceptsOutsideEdits == true || destinationDetail?.acceptsOutsideEdits == true
            || (scopeList?.selectedScope != nil && detail?.acceptsOutsideEdits == true))
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

    /// New Folder… (⇧⌘N, v0.7.0), or New Subfolder… in `parent`.
    func newFolder(in parent: FolderID? = nil) {
        guard isUnlocked else { return }
        present(.folderName(FolderNameContext(mode: .create(itemIDs: [], parent: parent))))
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

    /// New Environment… on a repository's context menu (1.0), by the scopes column's rule.
    func canCreateEnvironment(in repo: SidebarRepoModel) -> Bool {
        ScopeListViewModel.canCreateEnvironment(in: repo.importedRepoID.flatMap(sidebar.vaultRepository))
    }

    func newEnvironment(in repo: SidebarRepoModel) {
        guard canCreateEnvironment(in: repo), let id = repo.importedRepoID else { return }
        present(.newEnvironment(NewEnvironmentContext(repositoryID: id)))
    }

    /// The sidebar panel is hidden (View › Hide Sidebar, ⌃⌘S); Edit › Find brings it back.
    var isSidebarHidden = false

    /// The sidebar panel's width: the one being dragged on its trailing gutter, else the saved one
    /// (``PreferencesManager/sidebarWidth``).
    var sidebarWidth: CGFloat {
        draggedSidebarWidth ?? CGFloat(app.container.preferences.sidebarWidth)
    }

    /// The width while the gutter is dragged, within the tokens; saved once, when the drag ends.
    private(set) var draggedSidebarWidth: CGFloat?

    func dragSidebar(to width: CGFloat) {
        draggedSidebarWidth = CGFloat(PreferencesManager.validatedSidebarWidth(Int(width.rounded())))
    }

    func endSidebarDrag() {
        guard let width = draggedSidebarWidth else { return }
        app.container.preferences.sidebarWidth = Int(width)
        draggedSidebarWidth = nil
    }

    /// View › Hide Sidebar / Show Sidebar (⌃⌘S).
    func toggleSidebar() {
        isSidebarHidden.toggle()
    }

    /// Edit › Find (⌘F): closes the ⌘K palette (it would keep the focus), shows the sidebar if
    /// it was hidden, then focuses its search field.
    func findInSidebar() {
        jumpPalette = nil
        isSidebarHidden = false
        sidebar.focusSearch()
    }

    func lock() {
        app.lock(trigger: .manual)
    }

    /// An owner's Approve (1.0 B4b): the approval sheet when gh can add the scopes here (a
    /// scope of the fixed list, on gh's active account at the last reload; the router refuses
    /// the sheet offline, `needsInternet`). False leaves it to Settings › Accounts, whose
    /// commands switch accounts first.
    func approve(_ owner: SidebarOwnerModel) -> Bool {
        guard let scopes = owner.problem?.approvalScopes, sidebar.isActiveAccount(owner.accountLogin) else {
            return false
        }
        let sheet = MainSheet.ghApproval(GHApprovalContext(login: owner.accountLogin, ownerLogin: owner.login, scopes: scopes))
        present(sheet)
        return activeSheet == sheet
    }

    /// An owner's "Approve" or "Settings": Settings › Accounts has the commands that fix it.
    func requestAccountsSettings() {
        app.showSettings(.accounts)
    }

    /// Shows the "recovery key not confirmed" banner (the vault locked during onboarding or a
    /// recovery reset before the key was saved).
    var showsRecoveryKeyReminder: Bool {
        app.container.preferences.isRecoveryKeyConfirmationPending
    }

    /// The banner's button: the key that was shown cannot be shown again, so Settings › Security
    /// opens on a new one.
    func createNewRecoveryKey() {
        app.showSettings(.security, securitySheet: .newRecoveryKey)
    }

    // MARK: - Jump palette (⌘K, 1.0 D6c2)

    /// The palette on screen, or nil.
    private(set) var jumpPalette: JumpPaletteViewModel?

    /// The toolbar's search button and ⌘K: unlocked, with no sheet over the window.
    var canJump: Bool {
        isUnlocked && activeSheet == nil && !app.isShowingSettings
    }

    /// ⌘K and the toolbar's search button: opens the palette with the sidebar's places, or
    /// closes it when it is open.
    func showJumpPalette() {
        guard jumpPalette == nil else {
            jumpPalette = nil
            return
        }
        guard canJump else { return }
        let input = jumpPlaceInput
        let config = app.container.data.config
        jumpPalette = JumpPaletteViewModel(
            places: JumpPlaces.places(input),
            items: { query in
                do {
                    return JumpPlaces.items(try config.itemNames(matching: query), in: input)
                } catch {
                    AppLog.ui.error("Jump palette could not read the names")
                    return []
                }
            },
            open: { [weak self] target in
                self?.jump(to: target)
            },
            openItem: { [weak self] item in
                self?.jump(to: item)
            }
        )
    }

    /// Esc or a click outside.
    func closeJumpPalette() {
        jumpPalette = nil
    }

    /// The place the quick vault's Expand asked for (1.0 Q1), once the window shows.
    func openRequestedPlace() {
        guard let target = app.takePlaceRequest() else { return }
        jump(to: target)
    }

    /// Selects the place in the sidebar (clearing its search so the row shows) and closes the
    /// palette.
    func jump(to target: JumpPlaceTarget) {
        jumpPalette = nil
        pendingRow = nil
        sidebar.searchText = ""
        switch target {
        case .organization(let id):
            sidebar.selectedOrganizationOwnerID = id
        case .repository(let id):
            select(repositoryRow: id)
        case .environment(let repositoryID, let environmentID):
            open(repositoryID: repositoryID, scope: .environment(environmentID))
        case .repositoryScope(let repositoryID):
            open(repositoryID: repositoryID, scope: .repository)
        case .keyVault(let id):
            sidebar.select(keyVaultID: id)
        case .folder(let id):
            sidebar.select(folderID: id)
        }
    }

    /// A name from "Secrets by name" (1.0 D6c5): opens its place, then selects its row once the
    /// place's detail shows it (a repository's scopes can arrive later).
    func jump(to item: JumpItemModel) {
        jump(to: item.target)
        // The row is selected in the table: the notes have no selection.
        show(.table)
        let selectRow = { [weak self] in
            self?.pendingRow = item.match
            self?.selectPendingRow()
        }
        // An edit with unsaved changes asks first: the row waits for Discard.
        if discardRequest != nil {
            discardResumes.append(selectRow)
        } else {
            selectRow()
        }
    }

    /// The row ⌘K opened, until its place's detail exists.
    @ObservationIgnored private var pendingRow: ItemNameMatchModel?

    private func selectPendingRow() {
        guard let row = pendingRow else { return }
        switch row.holder {
        case .place(.scope(let repositoryID, let scope)):
            guard let detail, detail.repositoryID == repositoryID, detail.scope == scope, destinationDetail == nil else { return }
            detail.kind = row.kind
            detail.selection = [row.id]
        case .place(.folder(let id)):
            guard let folderDetail, folderDetail.folderID == id else { return }
            folderDetail.kind = row.kind
            folderDetail.selection = [row.id]
        case .place(.destination(let id)):
            guard let destinationDetail, destinationDetail.destinationID == id else { return }
            destinationDetail.kind = row.kind
            destinationDetail.selection = [row.id]
        case .organization(let id):
            guard let organizationDetail, organizationDetail.organizationID == id else { return }
            organizationDetail.selection = [row.id]
        }
        pendingRow = nil
    }

    /// Another place chosen before the ⌘K row's detail showed it: that row must not be selected
    /// when its place opens later. Nothing selected yet, or a selection still pending, keeps it.
    private func dropPendingRowElsewhere() {
        guard let row = pendingRow, !sidebar.isSelectionPending else { return }
        let repository = selectedRepo?.importedRepoID
        let organization = sidebar.selectedOrganizationOwner?.organization?.id
        let folder = sidebar.selectedFolderID
        let vault = sidebar.selectedKeyVaultID
        guard repository != nil || organization != nil || folder != nil || vault != nil else { return }
        let isElsewhere: Bool
        switch row.holder {
        case .place(.scope(let id, let scope)):
            if repository != id || organization != nil || folder != nil || vault != nil {
                isElsewhere = true
            } else if let scopeList, scopeList.repositoryID == id {
                // Once the scopes are listed, another scope or a destination of the repository.
                isElsewhere = scopeList.selectedDestination != nil
                    || scopeList.selectedScope.map { $0.scope != scope } == true
            } else {
                isElsewhere = false
            }
        case .place(.folder(let id)):
            isElsewhere = folder != id
        case .place(.destination(let id)):
            isElsewhere = vault != id
        case .organization(let id):
            isElsewhere = organization != id
        }
        if isElsewhere {
            pendingRow = nil
        }
    }

    /// Every place the sidebar can show under its filter, whatever its search; environments are
    /// read from the vault (the sidebar only lists the selected repository's).
    private var jumpPlaceInput: JumpPlaceInputModel {
        var environments: [RepoID: [EnvironmentModel]] = [:]
        do {
            // One read for every repository: ⌘K opens at once even with many in the vault.
            environments = try app.container.data.config.environmentsByRepository()
        } catch {
            AppLog.ui.error("Jump palette could not read the environments")
        }
        return JumpPlaceInputModel(
            owners: SidebarGrouping.owners(sidebar.input, query: "", filter: sidebar.repoFilter, selectedRowID: sidebar.selectedRowID),
            environments: environments,
            keyVaults: sidebar.keyVaults,
            folders: sidebar.folders
        )
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
        // The places drop their edits on lock: nothing is left to ask about.
        discardRequest = nil
        discardResumes = []
        activeSheet = nil
        jumpPalette = nil
    }
}
