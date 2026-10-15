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
            HStack(spacing: Theme.Spacing.medium) {
                SegmentedPill(
                    selection: $viewModel.kind,
                    segments: [
                        .init(
                            value: ConfigKind.secret,
                            title: String(localized: "main.detail.kind.secrets", defaultValue: "Secrets"),
                            count: viewModel.count(of: .secret)
                        ),
                        .init(
                            value: ConfigKind.variable,
                            title: String(localized: "main.detail.kind.variables", defaultValue: "Variables"),
                            count: viewModel.count(of: .variable)
                        ),
                    ],
                    accessibilityLabel: String(localized: "main.detail.kind", defaultValue: "Kind")
                )
                .fixedSize()
                Spacer(minLength: 0)
                RepoDetailAddActions(viewModel: viewModel)
            }
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

/// Import .env file (outline circle), Paste multiple (outline pill) and Add secret / Add
/// variable (the tab's kind, primary pill). Paste and import default every row to the tab's
/// kind.
private struct RepoDetailAddActions: View {
    let viewModel: RepoDetailViewModel

    var body: some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            Button {
                viewModel.importEnvFile()
            } label: {
                Label(String(localized: "main.detail.importEnvFile", defaultValue: "Import .env File…"), systemImage: "square.and.arrow.down")
            }
            .fxIconButtonStyle()
            .help(String(localized: "main.detail.importEnvFile", defaultValue: "Import .env File…"))
            Button(String(localized: "main.detail.pasteMultiple", defaultValue: "Paste Multiple…")) {
                viewModel.pasteMultiple()
            }
            .fxButtonStyle(.outline)
            Button {
                viewModel.add()
            } label: {
                Label(addTitle, systemImage: "plus")
            }
            .fxButtonStyle(.primary)
            .help(String(
                localized: "main.detail.add.help",
                defaultValue: "Add one item, or paste many KEY=value lines at once (⌘V on the table)"
            ))
        }
        .fixedSize()
        .disabled(!viewModel.canEdit)
    }

    private var addTitle: String {
        viewModel.kind == .secret
            ? String(localized: "main.detail.addSecret", defaultValue: "Add Secret")
            : String(localized: "main.detail.addVariable", defaultValue: "Add Variable")
    }
}

/// The header (mockup Main): ENVIRONMENT or REPOSITORY, the scope's name in the large title,
/// visibility and capability tags, the branch rules in mono, then Clone and Refresh.
private struct RepoDetailHeader: View {
    let viewModel: RepoDetailViewModel
    let main: MainViewModel

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.large) {
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
            Spacer(minLength: 0)
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

/// The tags under the title ("Private", "Admin"), "Created by the next Sync" and the drift-check
/// error; for an environment, "Deployment branches: …" in mono with Edit on its own row below, so
/// the policy gets the full column width.
private struct RepoDetailChips: View {
    let viewModel: RepoDetailViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            chips
            if viewModel.scope.level == .environment, let policy = viewModel.branchPolicy {
                branchPolicyRow(policy)
            }
        }
    }

    private var chips: some View {
        HStack(spacing: Theme.Spacing.small) {
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
