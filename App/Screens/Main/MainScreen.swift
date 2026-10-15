import AppKit
import SwiftUI
import VaultCore

/// The main window (§10.4): a three-column split view (sidebar, scopes, detail), the toolbar and
/// the sheet router of the UI feature contract.
struct MainScreen: View {
    @State private var viewModel: MainViewModel

    init(app: AppViewModel) {
        _viewModel = State(initialValue: app.makeMainViewModel())
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(spacing: 0) {
            if let banner = viewModel.connectivityBanner {
                ConnectivityBannerView(banner: banner) {
                    Task { await viewModel.retryGitHub() }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                Divider()
            }
            splitView
        }
        .animation(Theme.Durations.standardAnimation, value: viewModel.connectivityBanner)
        .toolbar {
            MainToolbar(viewModel: viewModel)
        }
        .sheet(item: $viewModel.activeSheet) { sheet in
            MainSheetContent(sheet: sheet, main: viewModel)
        }
        .focusedSceneValue(\.mainViewModel, viewModel)
        .task(id: viewModel.app.ghStatus) {
            await viewModel.sidebar.reload()
        }
        .onAppear {
            viewModel.presentNextPendingImport()
        }
        .onChange(of: viewModel.app.pendingImports) {
            viewModel.presentNextPendingImport()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            viewModel.detail?.remaskAll()
        }
    }

    /// The three columns (sidebar, scopes, detail) under the connectivity banner.
    private var splitView: some View {
        @Bindable var sidebar = viewModel.sidebar
        return NavigationSplitView {
            SidebarView(main: viewModel)
                .navigationSplitViewColumnWidth(min: Theme.Layout.sidebarMinWidth, ideal: Theme.Layout.sidebarIdealWidth)
        } content: {
            ScopeColumnView(main: viewModel)
                .navigationSplitViewColumnWidth(min: Theme.Layout.scopeListMinWidth, ideal: Theme.Layout.scopeListIdealWidth)
        } detail: {
            DetailColumnView(main: viewModel)
                .frame(minWidth: Theme.Layout.detailMinWidth)
        }
        .searchable(
            text: $sidebar.searchText,
            placement: .sidebar,
            prompt: Text(String(localized: "main.search.prompt", defaultValue: "Search repositories"))
        )
    }
}

/// The toolbar (§10 Toolbar): New Repository, Import .env, Share, Lock and the prominent Sync.
private struct MainToolbar: ToolbarContent {
    let viewModel: MainViewModel

    var body: some ToolbarContent {
        if AppIdentity.isDevelopmentBuild {
            ToolbarItem(placement: .navigation) {
                DevBuildBadge()
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                viewModel.newRepository()
            } label: {
                Label(String(localized: "toolbar.newRepository", defaultValue: "New Repository"), systemImage: "plus.rectangle.on.folder")
            }
            .help(viewModel.networkHelp(String(localized: "toolbar.newRepository.help", defaultValue: "New Repository (⌘N)")))
            .disabled(!viewModel.canCreateRepository)

            Button {
                viewModel.importEnv()
            } label: {
                Label(String(localized: "toolbar.importEnv", defaultValue: "Import .env"), systemImage: "square.and.arrow.down")
            }
            .help(String(localized: "toolbar.importEnv.help", defaultValue: "Import a .env file into the selected scope (⇧⌘I)"))
            .disabled(!viewModel.canImportEnv)

            ShareMenu(viewModel: viewModel)

            Button {
                viewModel.lock()
            } label: {
                Label(String(localized: "toolbar.lock", defaultValue: "Lock"), systemImage: "lock")
            }
            .help(String(localized: "toolbar.lock.help", defaultValue: "Lock FX Vault (⌃⌘L)"))

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
}

/// "DEV" in the toolbar of Debug builds (FX Vault Dev), which use their own vault folder.
private struct DevBuildBadge: View {
    var body: some View {
        StatusChip(
            title: String(localized: "toolbar.devBuild", defaultValue: "DEV"),
            tint: Theme.Colors.warning
        )
        .help(String(
            localized: "toolbar.devBuild.help",
            defaultValue: "Development build (FX Vault Dev). It uses the FX Vault Dev vault, not the vault of the installed FX Vault."
        ))
        .accessibilityLabel(String(localized: "toolbar.devBuild.accessibility", defaultValue: "Development build"))
    }
}

/// Share › File… / Nearby… / Receive Nearby… / Nearby Chat… (its own window).
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
        if let scopeList = main.scopeList {
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
        }
    }
}

/// Column 3: the repository detail, the Import prompt for a repository not in the vault, or an
/// empty state.
private struct DetailColumnView: View {
    let main: MainViewModel

    var body: some View {
        Group {
            if let detail = main.detail {
                RepoDetailScreen(viewModel: detail, main: main)
            } else if let repo = main.selectedRepo {
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
        .background(Theme.Colors.background)
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
