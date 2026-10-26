import SwiftUI
import VaultCore
import VaultData

/// Column 3 (§10; boards Main2-Repository, Place-Table): the connectivity banner, the header
/// (name, "Environment · api-service · counts", the drift line, ⋯ More), the read-only
/// explanation, the Secrets | Variables pill with the selection's actions, and the table.
struct RepoDetailScreen: View {
    @Bindable var viewModel: RepoDetailViewModel
    let main: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.mediumPlus) {
            if let banner = main.connectivityBanner {
                MainConnectivityBanner(banner: banner, main: main)
            }
            RepoDetailHeader(viewModel: viewModel, main: main)
            if let reason = viewModel.readOnlyReason {
                Label(reason.localizedExplanation, systemImage: "lock")
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            RepoDetailControls(viewModel: viewModel)
            ConfigTableView(viewModel: viewModel)
            if let notice = viewModel.notice {
                Text(notice)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
            }
        }
        .fxPlaceColumn()
        // ⌘V anywhere in the detail column (the table, the Kind pill, the empty state): a
        // user-initiated paste opens the import preview prefilled (never a background read).
        // Paste is disabled in read-only scopes.
        .onPasteCommand(of: [.plainText], validator: viewModel.validatePaste) { providers in
            Task { await viewModel.handlePaste(providers) }
        }
        .errorAlert($viewModel.alert)
        .deleteItemsSheet(viewModel.deletionSheet) {
            viewModel.pendingDeletion = nil
        } confirm: {
            viewModel.confirmDeletion()
        }
        .modifier(ItemCopyConflictDialog(viewModel: viewModel))
    }
}

/// The Secrets | Variables pill, with the selection's actions on its right (or under it when the
/// column is too narrow) while several rows are selected (v0.4.0). Adding, pasting and importing
/// are in ⋯ More since 1.0.
private struct RepoDetailControls: View {
    @Bindable var viewModel: RepoDetailViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.medium) {
                ConfigKindPill(viewModel: viewModel)
                Spacer(minLength: 0)
                selectionActions
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                ConfigKindPill(viewModel: viewModel)
                selectionActions
            }
        }
    }

    @ViewBuilder
    private var selectionActions: some View {
        if viewModel.selection.count > 1 {
            RepoDetailSelectionActions(viewModel: viewModel)
        }
    }
}

/// What several selected rows can do (v0.4.0): their count, Push on Next Sync and Revert when
/// some of them allow it, Delete…, and Deselect. ⌘-click or ⇧-click selects rows, ⌘A all of
/// them; the context menu offers the same actions.
private struct RepoDetailSelectionActions: View {
    let viewModel: RepoDetailViewModel

    var body: some View {
        let rows = viewModel.selectedRows
        let actions = ConfigSelectionActionsModel(rows: rows)
        HStack(spacing: Theme.Spacing.mediumMinus) {
            Text(String(localized: "main.detail.selection.count", defaultValue: "\(rows.count) selected"))
                .fxTextStyle(.monoMeta)
                .foregroundStyle(Theme.Colors.mutedText)
            CopyToMenu(
                title: PlaceCopy.copyTo,
                rows: actions.deletable,
                viewModel: viewModel,
                showsChevron: true
            )
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fxButtonStyle(.outline)
            if !actions.pushable.isEmpty {
                Button(String(localized: "main.table.pushOnNextSync", defaultValue: "Push on Next Sync")) {
                    viewModel.pushOnNextSync(actions.pushable)
                }
                .fxButtonStyle(.outline)
                .disabled(!viewModel.canEdit)
            }
            if !actions.revertible.isEmpty {
                Button(String(localized: "main.table.revert", defaultValue: "Revert")) {
                    viewModel.revert(actions.revertible)
                }
                .fxButtonStyle(.outline)
            }
            Button(String(localized: "main.table.delete", defaultValue: "Delete…")) {
                viewModel.requestDeletion(of: actions.deletable)
            }
            .fxButtonStyle(.outline)
            .disabled(!viewModel.canEdit || actions.deletable.isEmpty)
            .help(viewModel.readOnlyReason?.localizedExplanation ?? "")
            Button {
                viewModel.clearSelection()
            } label: {
                Label(String(localized: "main.detail.selection.clear", defaultValue: "Deselect"), systemImage: "xmark")
            }
            .fxIconButtonStyle()
            .help(String(localized: "main.detail.selection.clear", defaultValue: "Deselect"))
        }
        .fixedSize()
    }
}

/// The header (boards Main2-Repository, Main2-Actions): the scope's name, its subline, the status
/// line (Refreshing…, "2 changed on GitHub · Review", or why the check failed) and ⋯ More.
private struct RepoDetailHeader: View {
    let viewModel: RepoDetailViewModel
    let main: MainViewModel

    var body: some View {
        PlaceHeader(
            title: viewModel.headerTitle,
            subline: viewModel.headerSubline,
            titleHelp: viewModel.repository?.fullName
        ) {
            if viewModel.isRefreshing {
                PlaceRefreshingLine()
            } else if let report = viewModel.driftReport, report.count > 0 {
                DriftBannerView(report: report) {
                    viewModel.reviewDrift()
                }
            } else if let error = viewModel.driftError {
                Label(error.title, systemImage: "exclamationmark.triangle")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .lineLimit(1)
                    .help(error.message)
            }
        } accessories: {
            CopyAllButton(isEnabled: viewModel.canCopyAll) {
                viewModel.copyAll()
            }
        } moreItems: {
            RepoDetailMoreItems(viewModel: viewModel, main: main)
        }
    }
}

/// ⋯ More of a repository scope (board Main2-Actions): New Secret and New Variable; Paste
/// Multiple…, Import .env…, Export .env… and Copy All; Copy To and Share Securely…; Deployment Branches…
/// (an environment), Clone… and Refresh; Delete Selected…. Actions the account may not take are
/// listed disabled.
private struct RepoDetailMoreItems: View {
    let viewModel: RepoDetailViewModel
    let main: MainViewModel

    var body: some View {
        PlaceItemMoreItems(viewModel: viewModel) {
            placeItems
        }
    }

    @ViewBuilder
    private var placeItems: some View {
        let scopeList = main.scopeList
        let scope = scopeList?.selectedScope
        Button(PlaceCopy.exportEnv) {
            if let scopeList, let scope {
                scopeList.exportEnv(scope)
            }
        }
        .disabled(!canExport(scopeList, scope))
        CopyAllMenuItem(isEnabled: viewModel.canCopyAll) {
            viewModel.copyAll()
        }
        Divider()
        CopyToMenu(title: PlaceCopy.copyTo, rows: viewModel.placeCopyRows, viewModel: viewModel)
        Button(PlaceCopy.shareSecurely) {
            if let scopeList, let scope {
                scopeList.share(scope)
            }
        }
        .disabled(!canExport(scopeList, scope))
        Divider()
        if viewModel.scope.level == .environment {
            Button(PlaceCopy.deploymentBranches) {
                viewModel.editBranchPolicy()
            }
            .disabled(!viewModel.canEdit)
            .help(branchesHelp)
        }
        Button(PlaceCopy.clone) {
            guard let folder = ClonePanel.folder(for: main), let repo = main.selectedRepo else { return }
            Task { await main.sidebar.clone(repo, into: folder) }
        }
        .disabled(!viewModel.canClone)
        .help(main.networkHelp(String(localized: "main.detail.clone.help", defaultValue: "Clone through the account's SSH alias")))
        Button(PlaceCopy.refresh) {
            Task { await viewModel.refresh() }
        }
        .disabled(!viewModel.canRefresh)
        .help(main.networkHelp(String(
            localized: "main.detail.refresh.help",
            defaultValue: "Read permissions and check GitHub for changes"
        )))
    }

    private func canExport(_ scopeList: ScopeListViewModel?, _ scope: ConfigScopeSummaryModel?) -> Bool {
        guard let scopeList, let scope else { return false }
        return scopeList.canExport(scope)
    }

    /// The policy in mono no longer sits under the title (1.0): its summary and the plan note
    /// (§10) are this item's help.
    private var branchesHelp: String {
        var parts: [String] = []
        if let policy = viewModel.branchPolicy {
            parts.append(String(localized: "main.detail.branches", defaultValue: "Deployment branches: \(policy.localizedSummary)"))
        }
        if viewModel.showsPlanNote {
            parts.append(String(
                localized: "main.detail.planNote",
                defaultValue: "Some environment features on private repositories depend on your GitHub plan."
            ))
        }
        return parts.joined(separator: " ")
    }
}

/// Shown in the detail column for a repository that is not in the vault yet.
struct RepoImportPromptView: View {
    let repo: SidebarRepoModel
    let sidebar: SidebarViewModel

    var body: some View {
        EmptyStateView(
            systemImage: "square.and.arrow.down.on.square",
            title: repo.fullName,
            message: String(
                localized: "main.import.message",
                defaultValue: "Import this repository to manage its environments, secrets and variables. Secrets arrive without values: GitHub never returns them."
            )
        ) {
            if sidebar.isBusy(repo) {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(String(localized: "main.import.button", defaultValue: "Import")) {
                    Task { await sidebar.importRepository(repo) }
                }
                .fxButtonStyle(.primary, size: .large)
                .disabled(!sidebar.canImport(repo))
                .accessibilityIdentifier(AccessibilityID.Main.importRepository)
            }
            if !sidebar.isOnline {
                Text(ConnectivityCopy.offlineHelp)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
            } else if !sidebar.isGitHubReady {
                Text(String(localized: "main.import.needsGH", defaultValue: "Importing needs the GitHub CLI."))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
            }
        }
    }
}

/// The rows of a selection each action applies to (v0.4.0): the selection bar and the context
/// menu offer an action only when some rows allow it, and act on those rows only.
struct ConfigSelectionActionsModel {
    let deletable: [ConfigRowModel]
    let revertible: [ConfigRowModel]
    let pushable: [ConfigRowModel]

    init(rows: [ConfigRowModel]) {
        deletable = rows.filter { !$0.isDeleted }
        revertible = rows.filter(\.canRevert)
        pushable = rows.filter(\.canPushOnNextSync)
    }
}

extension ConfigDeletionModel {
    /// The first three names, then "and N more".
    static func names(_ names: [String]) -> String {
        let shown = Array(names.prefix(3)).formatted(.list(type: .and))
        guard names.count > 3 else { return shown }
        return String(localized: "main.detail.delete.names.more", defaultValue: "\(names.prefix(3).joined(separator: ", ")) and \(names.count - 3) more")
    }
}

extension ItemCopyRequestModel {
    var title: String {
        conflicts.count == 1
            ? String(localized: "main.detail.copy.conflict.title.one", defaultValue: "\(targetTitle) already has \(conflicts[0])")
            : String(localized: "main.detail.copy.conflict.title", defaultValue: "\(targetTitle) already has \(conflicts.count) of these items")
    }

    var replaceTitle: String {
        conflicts.count == 1
            ? String(localized: "main.detail.copy.conflict.replace.one", defaultValue: "Replace Its Value")
            : String(localized: "main.detail.copy.conflict.replace", defaultValue: "Replace \(conflicts.count) Values")
    }

    var message: String {
        String(
            localized: "main.detail.copy.conflict.message",
            defaultValue: "Replace sets the copied values there (\(ConfigDeletionModel.names(conflicts))); Keep Existing leaves them as they are. The other items are copied either way, as changes for the next Sync."
        )
    }
}
