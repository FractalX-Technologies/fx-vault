import AppKit
import SwiftUI
import VaultCore

/// The main window (§10.4; mockups Main2-Home and Main2-Repository): a two-column split view (the
/// sidebar tree and the selected place), the toolbar and the sheet router of the UI feature
/// contract. The connectivity banner sits at the top of the detail column.
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
                if viewModel.app.phase == .unlocked {
                    viewModel.retiredDestinations.load()
                }
                viewModel.presentNextPendingImport()
            }
            .alert(
                DestinationCopy.retiredTitle,
                isPresented: Binding(
                    get: { !viewModel.retiredDestinations.labels.isEmpty },
                    set: { if !$0 { viewModel.retiredDestinations.dismiss() } }
                )
            ) {
                Button(String(localized: "common.ok", defaultValue: "OK")) {
                    viewModel.retiredDestinations.dismiss()
                }
                .keyboardShortcut(.defaultAction)
            } message: {
                Text(DestinationCopy.retiredMessage(viewModel.retiredDestinations.labels))
            }
            .onChange(of: viewModel.app.pendingImports) {
                viewModel.presentNextPendingImport()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                viewModel.detail?.remaskAll()
                viewModel.folderDetail?.remaskAll()
            }
    }

    /// The two columns (sidebar tree, detail), each as tall as the window
    /// (`mainColumnHeight()`).
    private var splitView: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            SidebarView(main: viewModel)
                .mainColumnHeight()
                .navigationSplitViewColumnWidth(min: Theme.Layout.sidebarMinWidth, ideal: Theme.Layout.sidebarIdealWidth)
        } detail: {
            DetailColumnView(main: viewModel)
                .frame(minWidth: Theme.Layout.detailMinWidth)
                .mainColumnHeight()
        }
    }

    /// View › Hide Sidebar and Edit › Find (which brings the sidebar back) meet in
    /// ``MainViewModel/isSidebarHidden``.
    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { viewModel.isSidebarHidden ? .detailOnly : .all },
            set: { viewModel.isSidebarHidden = $0 == .detailOnly }
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

/// Installs the toolbar. The window title is drawn by ``MainToolbarTitle`` (mark and the
/// selected place's path), so the system title is removed; every item hides the shared glass so the
/// pills keep their own fill (docs/DESIGN.md).
private struct MainToolbarModifier: ViewModifier {
    let viewModel: MainViewModel

    func body(content: Content) -> some View {
        content
            .toolbar { MainToolbar(viewModel: viewModel) }
            .toolbar(removing: .title)
    }
}

/// The toolbar (§10 Toolbar; mockup Main2-Repository): the mark and the mono
/// `GitHub › owner › repo › environment` path; the search field; New repository, Import .env, Share and Lock as outline circles; Sync
/// last. Import .env is not on the mockup but stays: it is the import without a default kind
/// that remains enabled offline (ARCHITECTURE decisions 39 and 51).
private struct MainToolbar: ToolbarContent {
    let viewModel: MainViewModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            MainToolbarTitle(viewModel: viewModel)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItemGroup(placement: .primaryAction) {
            MainToolbarActions(viewModel: viewModel)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            MainSyncButton(viewModel: viewModel)
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

/// The mark, then the selected place as a mono path (``MainViewModel/breadcrumb``), or the app
/// name with nothing selected, and in Debug builds the DEV chip. It is `toolbarTitleWidth` wide:
/// a long path drops its first steps down to the last one, then the whole path, rather than
/// pushing the buttons.
struct MainToolbarTitle: View {
    let viewModel: MainViewModel

    var body: some View {
        let path = viewModel.breadcrumb
        ViewThatFits(in: .horizontal) {
            ForEach(Self.fallbacks(path), id: \.self) { steps in
                row(steps)
            }
        }
        .frame(width: Theme.Layout.toolbarTitleWidth, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.small)
        .help(path.joined(separator: Self.separator))
    }

    private static let separator = " › "

    /// The rows to try, widest first: the path, its tails down to the last step, then the app name.
    static func fallbacks(_ path: [String]) -> [[String]] {
        path.indices.map { Array(path.dropFirst($0)) } + [[]]
    }

    private func row(_ path: [String]) -> some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            BrandMark()
            if path.isEmpty {
                Text(AppIdentity.windowTitle)
                    .fxTextStyle(.headline)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Text(verbatim: path.joined(separator: Self.separator))
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityIdentifier(AccessibilityID.Main.breadcrumb)
            }
            if AppIdentity.isDevelopmentBuild {
                DevBuildBadge()
            }
        }
    }
}

/// New repository, Import .env and Share as 32 pt outline circles (Lock is at the bottom of the
/// sidebar, 1.0).
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

/// Share Project… as an outline circle.
private struct ShareMenu: View {
    let viewModel: MainViewModel

    var body: some View {
        Button {
            viewModel.shareProject()
        } label: {
            Label(String(localized: "toolbar.share", defaultValue: "Share"), systemImage: "square.and.arrow.up")
        }
        .disabled(!viewModel.canShareProject)
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
        case .orgItemEditor(let context):
            OrgItemEditorScreen(context: context, dependencies: dependencies)
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
            ProjectShareScreen(context: context, dependencies: dependencies)
        case .shareImport(let context):
            ShareImportScreen(context: context, dependencies: dependencies)
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

/// The detail column: the selected place (a repository scope, a destination, a folder or an
/// organization), the Import prompt for a repository or organization not in the vault, or an
/// empty state. The detail draws the connectivity banner itself (above its header); the other
/// states show it here.
private struct DetailColumnView: View {
    let main: MainViewModel

    var body: some View {
        Group {
            if let folderDetail = main.folderDetail {
                FolderDetailScreen(viewModel: folderDetail, main: main)
            } else if let organizationDetail = main.organizationDetail {
                OrganizationDetailScreen(viewModel: organizationDetail, main: main)
            } else if let destinationDetail = main.destinationDetail {
                DestinationDetailScreen(viewModel: destinationDetail, main: main)
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
                    } else if let owner = main.sidebar.selectedOrganizationOwner {
                        OrganizationImportPromptView(owner: owner, sidebar: main.sidebar)
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
