import SwiftUI
import VaultCore

/// The main window (§10.4): a three-column split view (sidebar, scopes, detail table) and the
/// toolbar with Lock and the Sync button.
struct MainScreen: View {
    @State private var viewModel: MainViewModel

    init(app: AppViewModel) {
        _viewModel = State(initialValue: app.makeMainViewModel())
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        NavigationSplitView {
            SidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: Theme.Layout.sidebarMinWidth, ideal: Theme.Layout.sidebarIdealWidth)
        } content: {
            ScopeListView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: Theme.Layout.scopeListMinWidth, ideal: Theme.Layout.scopeListIdealWidth)
        } detail: {
            RepoDetailPlaceholderView(viewModel: viewModel)
                .frame(minWidth: Theme.Layout.detailMinWidth)
        }
        .searchable(
            text: $viewModel.searchText,
            placement: .sidebar,
            prompt: Text(String(localized: "main.search.prompt", defaultValue: "Search repositories"))
        )
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    viewModel.lock()
                } label: {
                    Label(String(localized: "toolbar.lock", defaultValue: "Lock"), systemImage: "lock")
                }
                .help(String(localized: "toolbar.lock.help", defaultValue: "Lock FX Vault (⌃⌘L)"))

                SyncToolbarButton(
                    count: viewModel.pendingChangeCount,
                    isSyncing: viewModel.isSyncing,
                    isEnabled: viewModel.canSync
                ) {
                    viewModel.sync()
                }
            }
        }
        .sheet(isPresented: $viewModel.isShowingSync) {
            EmptyStateView(
                systemImage: "arrow.triangle.2.circlepath",
                title: String(localized: "sync.placeholder.title", defaultValue: "Sync"),
                message: String(
                    localized: "sync.placeholder.message",
                    defaultValue: "The sync summary appears here."
                )
            ) {
                Button(String(localized: "common.close", defaultValue: "Close")) {
                    viewModel.isShowingSync = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .frame(width: Theme.Layout.sheetWidth)
        }
    }
}

/// Column 1: accounts, owners and repositories.
struct SidebarView: View {
    @Bindable var viewModel: MainViewModel

    var body: some View {
        let owners = viewModel.owners
        VStack(spacing: 0) {
            if viewModel.showsRecoveryKeyReminder {
                RecoveryKeyReminderView()
            }
            if owners.isEmpty {
                EmptyStateView(
                    systemImage: "person.crop.circle.badge.questionmark",
                    title: String(localized: "main.sidebar.empty.title", defaultValue: "No repositories yet"),
                    message: String(
                        localized: "main.sidebar.empty.message",
                        defaultValue: "Repositories of your GitHub CLI accounts appear here."
                    )
                )
            } else {
                List(selection: $viewModel.selectedRepoID) {
                    ForEach(owners) { owner in
                        Section(owner.login) {
                            ForEach(owner.repos) { repo in
                                Label(repo.fullName, systemImage: repo.isPrivate ? "lock" : "book.closed")
                                    .opacity(repo.isImported ? 1 : Theme.Opacity.disabled)
                                    .tag(repo.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
}

/// The reminder shown when a recovery key was never confirmed as saved.
private struct RecoveryKeyReminderView: View {
    var body: some View {
        Label {
            Text(String(
                localized: "main.recoveryReminder",
                defaultValue: "Your recovery key was not saved. Create a new one in Settings › Security."
            ))
            .font(Theme.Typography.caption)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(Theme.Colors.warning)
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.warning.opacity(Theme.Opacity.chipBackground))
    }
}

/// Column 2: "Repository" and one row per environment.
struct ScopeListView: View {
    @Bindable var viewModel: MainViewModel

    var body: some View {
        let scopes = viewModel.scopes
        VStack(spacing: 0) {
            if scopes.isEmpty {
                EmptyStateView(
                    systemImage: "square.stack.3d.up",
                    title: String(localized: "main.scopes.empty.title", defaultValue: "No repository selected"),
                    message: String(
                        localized: "main.scopes.empty.message",
                        defaultValue: "Select a repository to see its environments."
                    )
                )
            } else {
                List(selection: $viewModel.selectedScopeID) {
                    ForEach(scopes) { scope in
                        HStack {
                            Text(scope.title)
                            Spacer()
                            if scope.missingValueCount > 0 {
                                Text(verbatim: scope.missingValueCount.formatted())
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Colors.warning)
                            }
                            if scope.hasPendingChanges {
                                Circle()
                                    .fill(Theme.Colors.pending)
                                    .frame(width: Theme.Layout.statusDotSize, height: Theme.Layout.statusDotSize)
                            }
                        }
                        .tag(scope.id)
                    }
                }
            }
            Divider()
            HStack {
                Button {
                } label: {
                    Label(String(localized: "main.scopes.newEnvironment", defaultValue: "New Environment"), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(true)
                Spacer()
            }
            .padding(Theme.Spacing.small)
        }
    }
}

/// Column 3: header, the Secrets | Variables picker and one table (§10.4).
struct RepoDetailPlaceholderView: View {
    @Bindable var viewModel: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack {
                Text(viewModel.selectedRepo?.fullName
                    ?? String(localized: "main.detail.noSelection", defaultValue: "No repository selected"))
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Spacer()
            }
            Picker(String(localized: "main.detail.kind", defaultValue: "Kind"), selection: $viewModel.selectedKind) {
                Text(String(localized: "main.detail.secrets", defaultValue: "Secrets")).tag(ConfigKind.secret)
                Text(String(localized: "main.detail.variables", defaultValue: "Variables")).tag(ConfigKind.variable)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Table(viewModel.rows, selection: $viewModel.selectedRowIDs) {
                TableColumn(String(localized: "main.table.name", defaultValue: "Name")) { row in
                    Text(verbatim: row.name)
                        .font(Theme.Typography.monospaced)
                }
                .width(min: Theme.Layout.tableNameMinWidth)
                TableColumn(String(localized: "main.table.value", defaultValue: "Value")) { row in
                    MaskedValueCell(display: row.value) { nil }
                }
                .width(min: Theme.Layout.tableValueMinWidth)
                TableColumn(String(localized: "main.table.updated", defaultValue: "Updated")) { row in
                    Text(row.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .width(min: Theme.Layout.tableDateMinWidth)
                TableColumn(String(localized: "main.table.status", defaultValue: "Status")) { row in
                    StatusChip(status: row.status)
                }
                .width(min: Theme.Layout.tableStatusMinWidth)
            }
            .overlay {
                if viewModel.rows.isEmpty {
                    EmptyStateView(
                        systemImage: viewModel.selectedKind == .secret ? "key" : "textformat",
                        title: viewModel.selectedKind == .secret
                            ? String(localized: "main.table.empty.secrets", defaultValue: "No secrets")
                            : String(localized: "main.table.empty.variables", defaultValue: "No variables"),
                        message: String(
                            localized: "main.table.empty.message",
                            defaultValue: "Select a repository and a scope to see its items."
                        )
                    )
                }
            }
        }
        .padding(Theme.Spacing.large)
        .background(Theme.Colors.background)
    }
}

#Preview {
    if let container = try? AppContainer.preview() {
        MainScreen(app: AppViewModel(container: container))
            .frame(width: Theme.Layout.windowDefaultWidth, height: Theme.Layout.windowDefaultHeight)
    }
}
