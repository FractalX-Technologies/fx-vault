import AppKit
import SwiftUI
import VaultCore

/// The main window (§10.4; mockup Main and MainDark): a three-column split view (sidebar,
/// scopes, detail), the toolbar and the sheet router of the UI feature contract. The
/// connectivity banner sits at the top of the detail column.
struct MainScreen: View {
    @State private var viewModel: MainViewModel

    init(app: AppViewModel) {
        _viewModel = State(initialValue: app.makeMainViewModel())
    }

    /// Shows an existing view model (previews and the visual snapshot tests).
    init(viewModel: MainViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        splitView
            .animation(Theme.Durations.spring, value: viewModel.connectivityBanner)
            .modifier(MainToolbarModifier(viewModel: viewModel))
            .sheet(item: $viewModel.activeSheet) { sheet in
                MainSheetContent(sheet: sheet, main: viewModel)
            }
            .focusedSceneValue(\.mainViewModel, viewModel)
            .task(id: viewModel.app.ghStatus) {
                await viewModel.sidebar.reload()
            }
            .onChange(of: viewModel.app.accountsRevision) {
                Task { await viewModel.sidebar.reload() }
            }
            .onAppear {
                viewModel.presentNextPendingImport()
                viewModel.app.teamPresence.setBrowsing(NSApp?.isActive ?? true)
            }
            .onDisappear {
                viewModel.app.teamPresence.setBrowsing(false)
            }
            .onChange(of: viewModel.app.pendingImports) {
                viewModel.presentNextPendingImport()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                viewModel.detail?.remaskAll()
                viewModel.folderDetail?.remaskAll()
                // Teammates nearby browses only while FX Vault is active (T8).
                viewModel.app.teamPresence.setBrowsing(false)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                viewModel.app.teamPresence.setBrowsing(true)
            }
    }

    /// The three columns (sidebar, scopes, detail), each as tall as the window
    /// (`mainColumnHeight()`).
    private var splitView: some View {
        @Bindable var sidebar = viewModel.sidebar
        return NavigationSplitView {
            SidebarView(main: viewModel)
                .mainColumnHeight()
                .navigationSplitViewColumnWidth(min: Theme.Layout.sidebarMinWidth, ideal: Theme.Layout.sidebarIdealWidth)
        } content: {
            ScopeColumnView(main: viewModel)
                .mainColumnHeight()
                .navigationSplitViewColumnWidth(min: Theme.Layout.scopeListMinWidth, ideal: Theme.Layout.scopeListIdealWidth)
        } detail: {
            DetailColumnView(main: viewModel)
                .frame(minWidth: Theme.Layout.detailMinWidth)
                .mainColumnHeight()
        }
        .searchable(
            text: $sidebar.searchText,
            placement: .toolbar,
            prompt: Text(String(localized: "main.search.prompt", defaultValue: "Search repositories"))
        )
    }
}

private extension View {
    /// Lets a column of the main split view take any height the window gives it. AppKit sizes the
    /// split view from each column's minimum height, which SwiftUI measures at zero width, where
    /// an empty state's wrapping message is about 1,000 pt tall. The split view then grew taller
    /// than the window and was centered in it: the top of every column slid under the title bar
    /// (traffic lights, sidebar toggle) and the sidebar footer dropped below the window. Each
    /// column scrolls or centers its own content; the window keeps its minimum size (RootScreen).
    func mainColumnHeight() -> some View {
        frame(minHeight: 0, maxHeight: .infinity)
    }
}

/// Installs the toolbar. The window title is drawn by ``MainToolbarTitle`` (mark, name and
/// repository path), so the system title is removed where macOS allows it (15+); on macOS 26+
/// every item hides the shared glass so the pills keep their own fill (docs/DESIGN.md).
private struct MainToolbarModifier: ViewModifier {
    let viewModel: MainViewModel

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .toolbar { GlasslessMainToolbar(viewModel: viewModel) }
                .toolbar(removing: .title)
        } else if #available(macOS 15, *) {
            content
                .toolbar { MainToolbar(viewModel: viewModel, showsAppName: true) }
                .toolbar(removing: .title)
        } else {
            content
                .toolbar { MainToolbar(viewModel: viewModel, showsAppName: false) }
        }
    }
}

/// The toolbar (§10 Toolbar; mockup Main): the mark, "FX Vault" and the mono `owner / repo`
/// path; the search field; New repository, Import .env, Share and Lock as outline circles; Sync
/// last. Import .env is not on the mockup but stays: it is the import without a default kind
/// that remains enabled offline (ARCHITECTURE decisions 39 and 51).
private struct MainToolbar: ToolbarContent {
    let viewModel: MainViewModel
    let showsAppName: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            MainToolbarTitle(viewModel: viewModel, showsAppName: showsAppName)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            MainToolbarActions(viewModel: viewModel)
        }
        ToolbarItem(placement: .primaryAction) {
            NearbyPresenceView(presence: viewModel.app.teamPresence, spaceSync: viewModel.app.spaceSync)
        }
        ToolbarItem(placement: .primaryAction) {
            MainSyncButton(viewModel: viewModel)
        }
    }
}

/// ``MainToolbar`` without the macOS 26 shared glass behind its items.
@available(macOS 26, *)
private struct GlasslessMainToolbar: ToolbarContent {
    let viewModel: MainViewModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            MainToolbarTitle(viewModel: viewModel, showsAppName: true)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItemGroup(placement: .primaryAction) {
            MainToolbarActions(viewModel: viewModel)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            NearbyPresenceView(presence: viewModel.app.teamPresence, spaceSync: viewModel.app.spaceSync)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            MainSyncButton(viewModel: viewModel)
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

/// The mark, the app name (when the system title is hidden), the selected repository as a mono
/// `owner / repo` path and, in Debug builds, the DEV chip. The native toolbar places it at the
/// scope column's leading edge (a `.navigation` item on the detail column lands there too), and
/// the scope/detail divider runs through the toolbar. So the title is `toolbarTitleWidth` wide
/// (the default scope column less the insets): it drops the path, then the app name, when they do
/// not fit, rather than crossing the divider, and the buttons after it start right of the divider.
private struct MainToolbarTitle: View {
    let viewModel: MainViewModel
    let showsAppName: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showsAppName: showsAppName, showsPath: true)
            row(showsAppName: showsAppName, showsPath: false)
            row(showsAppName: false, showsPath: false)
        }
        .frame(width: Theme.Layout.toolbarTitleWidth, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.small)
    }

    private func row(showsAppName: Bool, showsPath: Bool) -> some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            BrandMark()
            if showsAppName {
                Text(AppIdentity.windowTitle)
                    .fxTextStyle(.headline)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                    .fixedSize()
            }
            if showsPath, let repo = viewModel.selectedRepo {
                Text(verbatim: "\(repo.ownerLogin) / \(repo.name)")
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, Theme.Spacing.smallMinus)
                    .help(repo.fullName)
            }
            if AppIdentity.isDevelopmentBuild {
                DevBuildBadge()
            }
        }
    }
}

/// New repository, Import .env, Share and Lock as 32 pt outline circles.
private struct MainToolbarActions: View {
    let viewModel: MainViewModel

    var body: some View {
        Button {
            viewModel.newRepository()
        } label: {
            Label(String(localized: "toolbar.newRepository", defaultValue: "New Repository"), systemImage: "plus")
        }
        .fxIconButtonStyle()
        .help(viewModel.networkHelp(String(localized: "toolbar.newRepository.help", defaultValue: "New Repository (⌘N)")))
        .disabled(!viewModel.canCreateRepository)

        Button {
            viewModel.importEnv()
        } label: {
            Label(String(localized: "toolbar.importEnv", defaultValue: "Import .env"), systemImage: "square.and.arrow.down")
        }
        .fxIconButtonStyle()
        .help(String(localized: "toolbar.importEnv.help", defaultValue: "Import a .env file into the selected scope (⇧⌘I)"))
        .disabled(!viewModel.canImportEnv)

        ShareMenu(viewModel: viewModel)

        Button {
            viewModel.lock()
        } label: {
            Label(String(localized: "toolbar.lock", defaultValue: "Lock"), systemImage: "lock")
        }
        .fxIconButtonStyle()
        .help(String(localized: "toolbar.lock.help", defaultValue: "Lock FX Vault (⌃⌘L)"))
    }
}

/// The ink Sync pill with the mono pending count; 40% while it cannot run (offline included).
private struct MainSyncButton: View {
    let viewModel: MainViewModel

    var body: some View {
        SyncToolbarButton(
            count: viewModel.pendingChangeCount,
            isSyncing: viewModel.isSyncing,
            isEnabled: viewModel.canSync,
            unavailableReason: viewModel.isOnline ? nil : ConnectivityCopy.offlineHelp
        ) {
            viewModel.sync()
        }
    }
}

/// "DEV" in the toolbar of Debug builds (FX Vault Dev), which use their own vault folder.
private struct DevBuildBadge: View {
    var body: some View {
        StatusChip(
            title: String(localized: "toolbar.devBuild", defaultValue: "DEV"),
            tone: .warning
        )
        .help(String(
            localized: "toolbar.devBuild.help",
            defaultValue: "Development build (FX Vault Dev). It uses the FX Vault Dev vault, not the vault of the installed FX Vault."
        ))
        .accessibilityLabel(String(localized: "toolbar.devBuild.accessibility", defaultValue: "Development build"))
    }
}

/// Share › File… / Nearby… / Receive Nearby… / Nearby Chat… (its own window), as an outline
/// circle.
private struct ShareMenu: View {
    let viewModel: MainViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            Button(String(localized: "toolbar.share.file", defaultValue: "File…")) {
                viewModel.shareFile()
            }
            .disabled(!viewModel.canShareFile)
            Button(String(localized: "toolbar.share.nearby", defaultValue: "Nearby…")) {
                viewModel.shareNearby()
            }
            Divider()
            Button(String(localized: "toolbar.share.receive", defaultValue: "Receive Nearby…")) {
                viewModel.receiveNearby()
            }
            Divider()
            Button(String(localized: "toolbar.share.chat", defaultValue: "Nearby Chat…")) {
                openWindow(id: SceneID.nearbyChat)
            }
        } label: {
            Label(String(localized: "toolbar.share", defaultValue: "Share"), systemImage: "square.and.arrow.up")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fxIconButtonStyle()
        .help(String(localized: "toolbar.share.help", defaultValue: "Share configuration with a teammate"))
    }
}

/// Maps a ``MainSheet`` route to its feature entry view (UI feature contract).
private struct MainSheetContent: View {
    let sheet: MainSheet
    let main: MainViewModel

    var body: some View {
        let dependencies = main.featureDependencies
        switch sheet {
        case .itemEditor(let context):
            ItemEditorScreen(context: context, dependencies: dependencies)
        case .copyToRepository(let context):
            CopyToRepositoryScreen(context: context, dependencies: dependencies)
        case .newEnvironment(let context):
            NewEnvironmentScreen(context: context, dependencies: dependencies)
        case .environmentSettings(let context):
            EnvironmentSettingsScreen(context: context, dependencies: dependencies)
        case .renameEnvironment(let context):
            RenameEnvironmentScreen(context: context, dependencies: dependencies)
        case .duplicateEnvironment(let context):
            DuplicateEnvironmentScreen(context: context, dependencies: dependencies)
        case .sync(let context):
            SyncScreen(context: context, dependencies: dependencies)
        case .driftReview(let context):
            DriftReviewScreen(context: context, dependencies: dependencies)
        case .createRepository(let context):
            CreateRepoScreen(context: context, dependencies: dependencies)
        case .envImport(let context):
            EnvImportScreen(context: context, dependencies: dependencies)
        case .envExport(let context):
            EnvExportScreen(context: context, dependencies: dependencies)
        case .shareExport(let context):
            ShareExportScreen(context: context, dependencies: dependencies)
        case .shareImport(let context):
            ShareImportScreen(context: context, dependencies: dependencies)
        case .nearbySend(let context):
            NearbySendScreen(context: context, dependencies: dependencies)
        case .nearbyReceive(let context):
            NearbyReceiveScreen(context: context, dependencies: dependencies)
        case .shareSpace(let context):
            ShareSpaceScreen(context: context, dependencies: dependencies)
        case .space(let context):
            SpaceScreen(context: context, dependencies: dependencies)
        case .folderName(let context):
            FolderNameScreen(context: context, dependencies: dependencies)
        case .addDestination(let context):
            AddDestinationScreen(context: context, dependencies: dependencies)
        case .destinationSettings(let context):
            DestinationSettingsScreen(context: context, dependencies: dependencies)
        case .destinationDrift(let context):
            DestinationDriftScreen(context: context, dependencies: dependencies) { [weak main] in
                main?.destinationDetail?.clearRefresh()
            }
        case .addRepositoryByName(let context):
            AddRepositorySheet(viewModel: AddRepositoryViewModel(
                context: context,
                catalog: dependencies.catalog,
                connectivity: dependencies.connectivity,
                gitHubReachability: dependencies.gitHubReachability
            ) { [weak sidebar = main.sidebar] repo in
                sidebar?.didAddRepository(repo, accountLogin: context.accountLogin)
            })
        }
    }
}

/// Column 2: the scopes of the selected imported repository, or an empty state.
private struct ScopeColumnView: View {
    let main: MainViewModel

    var body: some View {
        if main.folderDetail != nil, let folder = main.sidebar.selectedFolder {
            FolderOverviewView(folder: folder, main: main)
        } else if let scopeList = main.scopeList {
            ScopeListView(viewModel: scopeList)
        } else {
            EmptyStateView(
                systemImage: "square.stack.3d.up",
                title: String(localized: "main.scopes.empty.title", defaultValue: "No repository selected"),
                message: String(
                    localized: "main.scopes.empty.message",
                    defaultValue: "Select an imported repository to see its environments."
                )
            )
            .background(Theme.Colors.ground)
        }
    }
}

/// Column 3: the repository detail, the Import prompt for a repository not in the vault, or an
/// empty state. The detail draws the connectivity banner itself (above its header); the other
/// states show it here.
private struct DetailColumnView: View {
    let main: MainViewModel

    var body: some View {
        Group {
            if let folderDetail = main.folderDetail {
                FolderDetailScreen(viewModel: folderDetail, main: main)
            } else if let destinationDetail = main.destinationDetail {
                DestinationDetailScreen(viewModel: destinationDetail, main: main)
            } else if let overview = main.overview {
                StageOverviewScreen(viewModel: overview, main: main)
            } else if let detail = main.detail {
                RepoDetailScreen(viewModel: detail, main: main)
            } else {
                VStack(spacing: 0) {
                    if let banner = main.connectivityBanner {
                        MainConnectivityBanner(banner: banner, main: main)
                            .padding(.horizontal, Theme.Spacing.xxLargePlus)
                            .padding(.top, Theme.Spacing.xLargePlus)
                    }
                    if let repo = main.selectedRepo {
                        RepoImportPromptView(repo: repo, sidebar: main.sidebar)
                    } else {
                        EmptyStateView(
                            systemImage: "key.horizontal",
                            title: String(localized: "main.detail.noSelection", defaultValue: "No repository selected"),
                            message: String(
                                localized: "main.detail.noSelection.message",
                                defaultValue: "Select a repository in the sidebar to see its secrets and variables."
                            )
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.ground)
    }
}

/// The connectivity banner of the main window, sliding in from the top; Retry re-checks GitHub.
struct MainConnectivityBanner: View {
    let banner: ConnectivityBannerModel
    let main: MainViewModel

    var body: some View {
        ConnectivityBannerView(banner: banner) {
            Task { await main.retryGitHub() }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Focused value (menu commands)

extension FocusedValues {
    /// The main window's view model, for the menu commands (⌘N, ⇧⌘I, Share, Sync).
    @Entry var mainViewModel: MainViewModel?
}

#Preview {
    if let container = try? AppContainer.preview() {
        MainScreen(app: AppViewModel(container: container))
            .frame(width: Theme.Layout.windowDefaultWidth, height: Theme.Layout.windowDefaultHeight)
    }
}
