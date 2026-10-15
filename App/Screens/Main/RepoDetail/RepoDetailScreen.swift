import SwiftUI
import VaultCore
import VaultData

/// Column 3 (§10): header, drift banner, environment notes, the read-only explanation and the
/// Secrets | Variables table.
struct RepoDetailScreen: View {
    @Bindable var viewModel: RepoDetailViewModel
    let main: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            RepoDetailHeader(viewModel: viewModel, main: main)
            if let report = viewModel.driftReport, report.count > 0 {
                DriftBannerView(report: report) {
                    viewModel.reviewDrift()
                }
            }
            if viewModel.scope.level == .environment {
                EnvironmentNotesView(viewModel: viewModel)
            }
            if let reason = viewModel.readOnlyReason {
                Label(reason.localizedExplanation, systemImage: "lock")
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Picker(String(localized: "main.detail.kind", defaultValue: "Kind"), selection: $viewModel.kind) {
                    Text(String(localized: "main.detail.secrets", defaultValue: "Secrets \(viewModel.count(of: .secret))"))
                        .tag(ConfigKind.secret)
                    Text(String(localized: "main.detail.variables", defaultValue: "Variables \(viewModel.count(of: .variable))"))
                        .tag(ConfigKind.variable)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                RepoDetailAddMenu(viewModel: viewModel)
            }
            ConfigTableView(viewModel: viewModel)
            if let notice = viewModel.notice {
                Text(notice)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .padding(Theme.Spacing.large)
        // ⌘V anywhere in the detail column (the table, the Kind picker, the empty state): a
        // user-initiated paste opens the import preview prefilled (never a background read).
        // Paste is disabled in read-only scopes.
        .onPasteCommand(of: [.plainText], validator: viewModel.validatePaste) { providers in
            Task { await viewModel.handlePaste(providers) }
        }
        .errorAlert($viewModel.alert)
        .confirmationDialog(
            String(localized: "main.detail.delete.title", defaultValue: "Delete this item?"),
            isPresented: deletionBinding,
            titleVisibility: .visible,
            presenting: viewModel.pendingDeletion
        ) { _ in
            Button(String(localized: "main.detail.delete.confirm", defaultValue: "Delete"), role: .destructive) {
                viewModel.confirmDeletion()
            }
        } message: { row in
            Text(String(
                localized: "main.detail.delete.message",
                defaultValue: "\(row.name) is deleted on GitHub by the next Sync, after you confirm the deletion there. Revert undoes it until then."
            ))
        }
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingDeletion != nil },
            set: { if !$0 { viewModel.pendingDeletion = nil } }
        )
    }
}

/// The Add split button: Add Secret / Add Variable (the tab's kind) as the primary action, plus
/// Paste Multiple… and Import .env File… (both default every row to the tab's kind).
private struct RepoDetailAddMenu: View {
    let viewModel: RepoDetailViewModel

    var body: some View {
        Menu {
            Button(addTitle) {
                viewModel.add()
            }
            Divider()
            Button(String(localized: "main.detail.pasteMultiple", defaultValue: "Paste Multiple…")) {
                viewModel.pasteMultiple()
            }
            Button(String(localized: "main.detail.importEnvFile", defaultValue: "Import .env File…")) {
                viewModel.importEnvFile()
            }
        } label: {
            Label(addTitle, systemImage: "plus")
        } primaryAction: {
            viewModel.add()
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(!viewModel.canEdit)
        .help(String(
            localized: "main.detail.add.help",
            defaultValue: "Add one item, or paste many KEY=value lines at once (⌘V on the table)"
        ))
    }

    private var addTitle: String {
        viewModel.kind == .secret
            ? String(localized: "main.detail.addSecret", defaultValue: "Add Secret")
            : String(localized: "main.detail.addVariable", defaultValue: "Add Variable")
    }
}

/// `owner/name`, visibility, capability chip, Clone and Refresh.
private struct RepoDetailHeader: View {
    let viewModel: RepoDetailViewModel
    let main: MainViewModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(verbatim: viewModel.repository?.fullName ?? "")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .textSelection(.enabled)
                HStack(spacing: Theme.Spacing.small) {
                    if let repository = viewModel.repository {
                        Text(repository.visibility.localizedTitle)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                        if !repository.existsOnGitHub {
                            StatusChip(
                                title: String(localized: "main.detail.notOnGitHub", defaultValue: "Created by the next Sync"),
                                tint: Theme.Colors.pending
                            )
                        }
                    }
                    if let capability = viewModel.capability {
                        StatusChip(title: capability.chipTitle, tint: capability.chipTint)
                    }
                    if let error = viewModel.driftError {
                        Label(error.title, systemImage: "exclamationmark.triangle")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .help(error.message)
                    }
                }
            }
            Spacer()
            Button {
                guard let folder = ClonePanel.folder(for: main), let repo = main.selectedRepo else { return }
                Task { await main.sidebar.clone(repo, into: folder) }
            } label: {
                Label(String(localized: "main.detail.clone", defaultValue: "Clone"), systemImage: "arrow.down.to.line")
            }
            .disabled(!viewModel.canClone)
            .help(main.networkHelp(String(localized: "main.detail.clone.help", defaultValue: "Clone through the account's SSH alias")))
            Button {
                Task { await viewModel.refresh() }
            } label: {
                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label(String(localized: "main.detail.refresh", defaultValue: "Refresh"), systemImage: "arrow.clockwise")
                }
            }
            .disabled(!viewModel.canRefresh)
            .help(main.networkHelp(String(
                localized: "main.detail.refresh.help",
                defaultValue: "Read permissions and check GitHub for changes"
            )))
        }
    }
}

/// "Deployment branches: Selected (2 rules) — Edit" and the plan note (§10 Column 3).
private struct EnvironmentNotesView: View {
    let viewModel: RepoDetailViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            if let policy = viewModel.branchPolicy {
                HStack(spacing: Theme.Spacing.small) {
                    Text(String(
                        localized: "main.detail.branches",
                        defaultValue: "Deployment branches: \(policy.localizedSummary)"
                    ))
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    Button(String(localized: "main.detail.branches.edit", defaultValue: "Edit")) {
                        viewModel.editBranchPolicy()
                    }
                    .buttonStyle(.link)
                    .disabled(!viewModel.canEdit)
                }
            }
            if viewModel.showsPlanNote {
                HStack(spacing: Theme.Spacing.xSmall) {
                    Text(String(
                        localized: "main.detail.planNote",
                        defaultValue: "Some environment features on private repositories depend on your GitHub plan."
                    ))
                    if let url = ExternalLinks.environmentPlans {
                        Link(String(localized: "main.detail.planNote.learnMore", defaultValue: "Learn more"), destination: url)
                    }
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
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
                .buttonStyle(.borderedProminent)
                .disabled(!sidebar.canImport(repo))
            }
            if !sidebar.isOnline {
                Text(ConnectivityCopy.offlineHelp)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            } else if !sidebar.isGitHubReady {
                Text(String(localized: "main.import.needsGH", defaultValue: "Importing needs the GitHub CLI."))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }
}
