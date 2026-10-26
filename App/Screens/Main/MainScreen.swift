import AppKit
import SwiftUI
import VaultCore

/// The main window (§10.4; boards Main2-Home, Main2-Repository, Main2-Search): a two-column split
/// view (the sidebar tree and the selected place), the toolbar, the ⌘K jump palette over both and
/// the sheet router of the UI feature contract. The banners sit at the top of the detail column.
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
            .overlay {
                JumpPaletteOverlay(main: viewModel)
            }
            .animation(Theme.Durations.interactionAnimation, value: viewModel.jumpPalette == nil)
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

/// The detail column: the recovery-key banner, then the selected place (a repository scope, a
/// destination, a folder or an organization), the Import prompt for a repository or organization
/// not in the vault, or the home. The detail draws the connectivity banner itself (above its
/// header); the other states show it here. No background of its own: the window's ground shows,
/// and the system's floating sidebar and glass toolbar stay as macOS draws them.
private struct DetailColumnView: View {
    let main: MainViewModel

    var body: some View {
        VStack(spacing: 0) {
            if main.showsRecoveryKeyReminder {
                RecoveryKeyBanner(main: main)
                    .padding(.horizontal, Theme.Spacing.xLargePlus)
                    .padding(.top, Theme.Spacing.large)
            }
            selectedPlace
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var selectedPlace: some View {
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
                            .padding(.horizontal, Theme.Spacing.xLargePlus)
                            .padding(.top, Theme.Spacing.largePlus)
                    }
                    if let repo = main.selectedRepo {
                        RepoImportPromptView(repo: repo, sidebar: main.sidebar)
                    } else if let owner = main.sidebar.selectedOrganizationOwner {
                        OrganizationImportPromptView(owner: owner, sidebar: main.sidebar)
                    } else {
                        MainHomeView(main: main)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The detail with nothing selected (board Main2-Home): the pending changes and the ⌘K hint.
private struct MainHomeView: View {
    let main: MainViewModel

    var body: some View {
        EmptyStateView(
            systemImage: "square.3.layers.3d",
            title: MainCopy.homeTitle,
            message: MainCopy.homePendingChanges(main.pendingChangeCount)
        ) {
            HStack(spacing: Theme.Spacing.small) {
                KeyHint("⌘K")
                Text(JumpPaletteCopy.toJumpAnywhere)
                    .fxTextStyle(.callout)
                    .foregroundStyle(Theme.Colors.mutedText)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(JumpPaletteCopy.jumpAnywhereHelp)
        }
    }
}

/// The recovery key was never confirmed as saved (board Main2-Home). The key that was shown
/// cannot be shown again, so the button opens Settings › Security on a new one.
private struct RecoveryKeyBanner: View {
    let main: MainViewModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Banner(
            .warning,
            message: MainCopy.recoveryKeyNotSaved,
            systemImage: "key",
            action: .init(title: MainCopy.createNewRecoveryKey) {
                main.createNewRecoveryKey()
                openSettings()
            }
        )
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
