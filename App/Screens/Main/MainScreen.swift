import AppKit
import SwiftUI
import VaultCore

/// The main window (§10.4; boards Main2-Home, Main2-Repository, Main2-Search): the sidebar panel
/// and, beside it, the toolbar panel, the recovery-key strip and the selected place, all on the
/// soft ground under a hidden title bar (``MainWindowTitleBar``); the ⌘K jump palette over them
/// and the sheet router of the UI feature contract.
struct MainScreen: View {
    @State private var viewModel: MainViewModel
    @State private var isFullScreen = false

    init(app: AppViewModel) {
        _viewModel = State(initialValue: app.makeMainViewModel())
    }

    /// Shows an existing view model (previews and the visual snapshot tests).
    init(viewModel: MainViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        panels
            .animation(Theme.Durations.spring, value: viewModel.connectivityBanner)
            .overlay {
                JumpPaletteOverlay(main: viewModel)
            }
            .animation(Theme.Durations.interactionAnimation, value: viewModel.jumpPalette == nil)
            .mainWindowChrome(isFullScreen: $isFullScreen)
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

    /// The panels, `mainPanelInset` from the window's edges and from each other, from the very
    /// top of the window: the traffic lights sit in the sidebar panel's top inset, or before the
    /// toolbar panel while the sidebar is hidden (View › Hide Sidebar slides it out). The gutters
    /// and the sidebar's top band move the window; the gutter after the sidebar resizes it.
    private var panels: some View {
        HStack(spacing: 0) {
            if !viewModel.isSidebarHidden {
                HStack(spacing: 0) {
                    SidebarView(main: viewModel)
                        .padding(.top, Theme.Layout.sidebarPanelTopInset)
                        .frame(width: viewModel.sidebarWidth)
                        .mainColumnHeight()
                        .fxGlassPanel()
                        .overlay(alignment: .top) {
                            WindowDragArea()
                                .frame(height: Theme.Layout.sidebarPanelTopInset)
                        }
                    SidebarResizeHandle(main: viewModel)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(spacing: Theme.Layout.mainPanelInset) {
                MainToolbarPanel(viewModel: viewModel)
                    // Full screen hides the traffic lights.
                    .padding(.leading, viewModel.isSidebarHidden && !isFullScreen ? Theme.Layout.trafficLightsWidth : 0)
                if viewModel.showsRecoveryKeyReminder {
                    RecoveryKeyStrip(main: viewModel)
                }
                DetailColumnView(main: viewModel)
                    .frame(minWidth: Theme.Layout.detailMinWidth)
                    .mainColumnHeight()
                    // Its empty parts (beside a title, around an empty state) are not chrome:
                    // without a shape the click reaches the ground's drag area behind.
                    .contentShape(Rectangle())
            }
        }
        .padding(Theme.Layout.mainPanelInset)
        // The same minimum with the sidebar hidden: showing it again never overflows the window.
        .frame(minWidth: Theme.Layout.mainScreenMinWidth)
        .ignoresSafeArea()
        .background {
            MainWindowGround()
                .overlay {
                    WindowDragArea()
                        .ignoresSafeArea()
                }
        }
        .animation(Theme.Durations.spring, value: viewModel.isSidebarHidden)
    }
}

/// The gutter between the sidebar panel and the detail: dragging it resizes the sidebar between
/// `sidebarMinWidth` and `sidebarMaxWidth`, saved per Mac user when the drag ends.
private struct SidebarResizeHandle: View {
    let main: MainViewModel
    // Resets itself when the drag ends or is cancelled (⌃⌘S mid-drag never calls onEnded).
    @GestureState private var startWidth: CGFloat?
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        Color.clear
            .frame(width: Theme.Layout.mainPanelInset)
            .mainColumnHeight()
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($startWidth) { drag, start, _ in
                        let origin = start ?? main.sidebarWidth
                        start = origin
                        // Global coordinates don't flip: right to left, the sidebar is on the right.
                        let delta = layoutDirection == .rightToLeft ? -drag.translation.width : drag.translation.width
                        main.dragSidebar(to: origin + delta)
                    }
                    .onEnded { _ in
                        main.endSidebarDrag()
                    }
            )
            // A cancelled drag never reaches onEnded: it keeps, and saves, the width it shows.
            .onChange(of: startWidth == nil) { _, isIdle in
                if isIdle {
                    main.endSidebarDrag()
                }
            }
            .accessibilityHidden(true)
    }
}

private extension View {
    /// Lets a column take any height the window gives it. SwiftUI measures a column's minimum
    /// height at zero width, where an empty state's wrapping message is about 1,000 pt tall; as a
    /// minimum it grew the window past the screen (the split view before D6c2b was centered in
    /// it, under the title bar). Each column scrolls or centers its own content.
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
        case .orgDrift(let context):
            OrgDriftScreen(context: context, dependencies: dependencies) { [weak main] resolved in
                main?.organizationDetail?.didResolve(resolved)
            }
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
        case .copyAll(let context):
            CopyAllScreen(context: context, dependencies: dependencies)
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

/// The detail under the toolbar panel: the selected place (a repository scope, a destination, a
/// folder or an organization), the Import prompt for a repository or organization not in the
/// vault, or the home. The detail draws the connectivity banner itself (above its header); the
/// other states show it here. No background of its own: the window's soft ground shows.
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

/// The recovery key was never confirmed as saved (board Main2-Home): a glass strip under the
/// toolbar panel. The key that was shown cannot be shown again, so the button opens Settings ›
/// Security on a new one (the board's "Show Key" is not offered).
private struct RecoveryKeyStrip: View {
    let main: MainViewModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "key")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.ink)
                .accessibilityHidden(true)
            Text(MainCopy.recoveryKeyNotSaved)
                .fxTextStyle(.calloutEmphasized)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button(MainCopy.createNewRecoveryKey) {
                main.createNewRecoveryKey()
                openSettings()
            }
            .fxButtonStyle(.secondary, size: .compact)
        }
        .padding(.leading, Theme.Spacing.mediumPlus)
        .padding(.trailing, Theme.Spacing.smallMinus)
        .frame(height: Theme.Layout.bannerStripHeight)
        .fxGlassPanel(radius: Theme.Radius.row)
        .accessibilityElement(children: .contain)
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
