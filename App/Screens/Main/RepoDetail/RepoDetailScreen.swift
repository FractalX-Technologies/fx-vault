import SwiftUI
import VaultCore
import VaultData

/// Column 3 (§10; mockup Main): the connectivity banner, the header (scope label, name, chips,
/// branch rules, Clone and Refresh), the drift banner, the plan note, the read-only explanation,
/// the Secrets | Variables pill with Paste multiple and Add, and the table.
struct RepoDetailScreen: View {
    @Bindable var viewModel: RepoDetailViewModel
    let main: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.largePlus) {
            if let banner = main.connectivityBanner {
                MainConnectivityBanner(banner: banner, main: main)
            }
            RepoDetailHeader(viewModel: viewModel, main: main)
            if let report = viewModel.driftReport, report.count > 0 {
                DriftBannerView(report: report) {
                    viewModel.reviewDrift()
                }
            }
            if viewModel.showsPlanNote {
                PlanNoteView()
            }
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
        .padding(.horizontal, Theme.Spacing.xxLargePlus)
        .padding(.vertical, Theme.Spacing.xLargePlus)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // ⌘V anywhere in the detail column (the table, the Kind pill, the empty state): a
        // user-initiated paste opens the import preview prefilled (never a background read).
        // Paste is disabled in read-only scopes.
        .onPasteCommand(of: [.plainText], validator: viewModel.validatePaste) { providers in
            Task { await viewModel.handlePaste(providers) }
        }
        .errorAlert($viewModel.alert)
        .confirmationDialog(
            viewModel.pendingDeletion?.title ?? "",
            isPresented: deletionBinding,
            titleVisibility: .visible,
            presenting: viewModel.pendingDeletion
        ) { deletion in
            Button(deletion.confirmTitle, role: .destructive) {
                viewModel.confirmDeletion()
            }
        } message: { deletion in
            Text(deletion.message)
        }
        .modifier(ItemCopyConflictDialog(viewModel: viewModel))
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingDeletion != nil },
            set: { if !$0 { viewModel.pendingDeletion = nil } }
        )
    }
}

/// The Secrets | Variables pill with the add actions on its right, or under it when the column is
/// too narrow for one row, so the actions never spill under the sidebar. While several rows
/// are selected, the selection's actions take the add actions' place (v0.4.0).
private struct RepoDetailControls: View {
    @Bindable var viewModel: RepoDetailViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.medium) {
                kindPill
                Spacer(minLength: 0)
                actions
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                kindPill
                actions
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if viewModel.selection.count > 1 {
            RepoDetailSelectionActions(viewModel: viewModel)
        } else {
            ConfigAddActions(viewModel: viewModel)
        }
    }

    private var kindPill: some View {
        ConfigKindPill(viewModel: viewModel)
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
                title: String(localized: "main.detail.selection.copyTo", defaultValue: "Copy To"),
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

/// The header (mockup Main): ENVIRONMENT or REPOSITORY, the scope's name in the large title,
/// visibility and capability tags, the branch rules in mono, then Clone and Refresh on the right,
/// or under the title when the column is too narrow for both.
private struct RepoDetailHeader: View {
    let viewModel: RepoDetailViewModel
    let main: MainViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: Theme.Spacing.large) {
                details
                Spacer(minLength: 0)
                actions
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                details
                actions
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
            SectionLabel(isEnvironment
                ? String(localized: "main.detail.environment", defaultValue: "Environment")
                : String(localized: "main.detail.repository", defaultValue: "Repository"))
            Text(verbatim: title)
                .fxTextStyle(.largeTitle)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(viewModel.repository?.fullName ?? "")
            RepoDetailChips(viewModel: viewModel)
                .padding(.top, Theme.Spacing.xSmall)
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.large) {
            Button(String(localized: "main.detail.clone", defaultValue: "Clone")) {
                guard let folder = ClonePanel.folder(for: main), let repo = main.selectedRepo else { return }
                Task { await main.sidebar.clone(repo, into: folder) }
            }
            .fxButtonStyle(.outline)
            .disabled(!viewModel.canClone)
            .help(main.networkHelp(String(localized: "main.detail.clone.help", defaultValue: "Clone through the account's SSH alias")))
            Button {
                Task { await viewModel.refresh() }
            } label: {
                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(String(localized: "main.detail.refresh", defaultValue: "Refresh"))
                } else {
                    Text(String(localized: "main.detail.refresh", defaultValue: "Refresh"))
                }
            }
            .fxButtonStyle(.secondary)
            .disabled(!viewModel.canRefresh)
            .help(main.networkHelp(String(
                localized: "main.detail.refresh.help",
                defaultValue: "Read permissions and check GitHub for changes"
            )))
            if let scopeList = main.scopeList, let scope = scopeList.selectedScope {
                ScopeActionsMenu(scope: scope, scopeList: scopeList)
            }
        }
    }

    private var isEnvironment: Bool {
        viewModel.scope.level == .environment
    }

    /// The environment's name, or the repository's name for the repository scope.
    private var title: String {
        if isEnvironment, let summary = viewModel.scopeSummary {
            return summary.title
        }
        return viewModel.repository?.name ?? ""
    }
}

/// The selected scope's actions as an outline circle in the header (v0.4.0): the scope row's
/// context menu (Settings, Rename, Duplicate, Export .env, Share, Revert, Delete for an
/// environment; Export .env and Share for the repository level), so they are not only a
/// right-click away. Actions the account may not take are listed disabled.
private struct ScopeActionsMenu: View {
    let scope: ConfigScopeSummaryModel
    let scopeList: ScopeListViewModel

    var body: some View {
        let label = scope.environment == nil
            ? String(localized: "main.detail.scopeActions.repository", defaultValue: "Repository Actions")
            : String(localized: "main.detail.scopeActions.environment", defaultValue: "Environment Actions")
        Menu {
            ScopeContextMenu(scope: scope, viewModel: scopeList)
        } label: {
            Label(label, systemImage: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fxIconButtonStyle()
        .help(label)
    }
}

/// The tags under the title ("Private", "Admin"), "Created by the next Sync" and the drift-check
/// error, in one row or stacked when the column is too narrow; for an environment, "Deployment
/// branches: …" in mono with Edit on its own row below, so the policy gets the full column width.
private struct RepoDetailChips: View {
    let viewModel: RepoDetailViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.small) {
                    chips
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                    chips
                }
            }
            if viewModel.scope.level == .environment, let policy = viewModel.branchPolicy {
                branchPolicyRow(policy)
            }
        }
    }

    @ViewBuilder
    private var chips: some View {
        if let repository = viewModel.repository {
            StatusChip.tag(repository.visibility.localizedTitle)
            if !repository.existsOnGitHub {
                StatusChip(
                    title: String(localized: "main.detail.notOnGitHub", defaultValue: "Created by the next Sync"),
                    tone: .brand
                )
            }
        }
        if let capability = viewModel.capability {
            if case .full = capability {
                StatusChip.tag(capability.chipTitle)
            } else {
                StatusChip(title: capability.chipTitle, tint: capability.chipTint)
            }
        }
        if let error = viewModel.driftError {
            Label(error.title, systemImage: "exclamationmark.triangle")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.mutedText)
                .lineLimit(1)
                .fixedSize()
                .help(error.message)
        }
    }

    private func branchPolicyRow(_ policy: DeploymentBranchPolicyModel) -> some View {
        let text = String(
            localized: "main.detail.branches",
            defaultValue: "Deployment branches: \(policy.localizedSummary)"
        )
        return HStack(spacing: Theme.Spacing.small) {
            Text(text)
                .fxTextStyle(.monoMeta)
                .foregroundStyle(Theme.Colors.subtleText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(text)
            Button(String(localized: "main.detail.branches.edit", defaultValue: "Edit")) {
                viewModel.editBranchPolicy()
            }
            .fxLinkButtonStyle(isEmphasized: true)
            .disabled(!viewModel.canEdit)
        }
    }
}

/// The plan note (§10): environment features on private repositories depend on the plan.
private struct PlanNoteView: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            Text(String(
                localized: "main.detail.planNote",
                defaultValue: "Some environment features on private repositories depend on your GitHub plan."
            ))
            .foregroundStyle(Theme.Colors.mutedText)
            if let url = ExternalLinks.environmentPlans {
                Link(String(localized: "main.detail.planNote.learnMore", defaultValue: "Learn more"), destination: url)
                    .foregroundStyle(Theme.Colors.brand)
            }
        }
        .font(Theme.Typography.caption)
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
    var title: String {
        rows.count == 1
            ? String(localized: "main.detail.delete.title", defaultValue: "Delete this item?")
            : String(localized: "main.detail.delete.several.title", defaultValue: "Delete \(rows.count) items?")
    }

    var confirmTitle: String {
        rows.count == 1
            ? String(localized: "main.detail.delete.confirm", defaultValue: "Delete")
            : String(localized: "main.detail.delete.several.confirm", defaultValue: "Delete \(rows.count) Items")
    }

    var message: String {
        let synced = syncedRows
        let onGitHub = if synced.count == 1, let row = synced.first {
            String(
                localized: "main.detail.delete.message",
                defaultValue: "\(row.name) is deleted on GitHub by the next Sync, after you confirm the deletion there. Revert undoes it until then."
            )
        } else {
            String(
                localized: "main.detail.delete.several.message",
                defaultValue: "\(Self.names(synced.map(\.name))) are deleted on GitHub by the next Sync, after you confirm the deletion there. Revert undoes it until then."
            )
        }
        switch unsyncedCount {
        case 0:
            return onGitHub
        case 1:
            let local = String(localized: "main.detail.delete.unsynced.one", defaultValue: "The one never synced is removed now.")
            return "\(onGitHub) \(local)"
        default:
            let local = String(
                localized: "main.detail.delete.unsynced.several",
                defaultValue: "The \(unsyncedCount) never synced are removed now."
            )
            return "\(onGitHub) \(local)"
        }
    }

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
