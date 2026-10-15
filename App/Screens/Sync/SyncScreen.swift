import SwiftUI

/// The Sync sheet (§10 Sheets): Summary → Deletions (live fetch) → Progress → Result. Holds a
/// SyncActivity for the whole run (``SyncViewModel``).
///
/// UI feature contract entry view (ARCHITECTURE.md): presented by `MainScreen` for
/// `MainSheet.sync`. The init signature is fixed. Dismiss with `@Environment(\.dismiss)`.
struct SyncScreen: View {
    @State private var viewModel: SyncViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: SyncContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: SyncViewModel(
            context: context,
            dependencies: dependencies,
            chooseCloneFolder: { ClonePanel.folder(preferences: dependencies.preferences) }
        ))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            SyncFooterView(buttons: viewModel.buttons, notice: viewModel.footerNotice) { action in
                if viewModel.perform(action) {
                    dismiss()
                }
            }
        }
        .frame(
            minWidth: Theme.Layout.syncSheetWidth,
            idealWidth: Theme.Layout.syncSheetWidth,
            maxWidth: Theme.Layout.syncSheetWidth,
            minHeight: Theme.Layout.syncSheetMinHeight,
            idealHeight: Theme.Layout.syncSheetIdealHeight
        )
        .interactiveDismissDisabled(viewModel.blocksDismissal)
        .errorAlert($viewModel.alert)
        .task {
            await viewModel.load()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Colors.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(subtitle)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if viewModel.step == .summary || viewModel.step == .result {
                Button {
                    viewModel.copySummary()
                } label: {
                    Label(String(localized: "sync.copyReport", defaultValue: "Copy as Text"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(String(
                    localized: "sync.copyReport.help",
                    defaultValue: "Copy the names and counts as plain text. Values are never included."
                ))
            }
        }
        .padding(Theme.Spacing.large)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.step {
        case .loading:
            VStack(spacing: Theme.Spacing.small) {
                ProgressView()
                Text(String(localized: "sync.loading", defaultValue: "Checking what GitHub has…"))
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        case .failed(let error):
            EmptyStateView(systemImage: "exclamationmark.triangle", title: error.title, message: error.message) {
                EmptyView()
            }
        case .summary:
            SyncSummaryView(viewModel: viewModel)
        case .deletions:
            SyncDeletionsView(viewModel: viewModel)
        case .progress:
            SyncRunView(progress: viewModel.progress, writeBudgetLine: viewModel.writeBudgetLine)
        case .result:
            SyncResultView(viewModel: viewModel)
        }
    }

    private var title: String {
        switch viewModel.step {
        case .deletions:
            String(localized: "sync.deletions.title", defaultValue: "Review Deletions")
        case .result:
            viewModel.stopReason == nil
                ? String(localized: "sync.result.title", defaultValue: "Sync Finished")
                : String(localized: "sync.result.title.stopped", defaultValue: "Sync Stopped")
        default:
            String(localized: "sync.title", defaultValue: "Sync")
        }
    }

    private var subtitle: String {
        switch viewModel.step {
        case .loading, .failed:
            String(localized: "sync.subtitle.loading", defaultValue: "Pushes your vault's pending changes to GitHub.")
        case .summary:
            String(
                localized: "sync.subtitle.summary",
                defaultValue: "What changes on GitHub. Names only: values are never shown here."
            )
        case .deletions:
            String(
                localized: "sync.subtitle.deletions",
                defaultValue: "These are deleted on GitHub. Deleted secrets cannot be recovered from GitHub."
            )
        case .progress:
            String(
                localized: "sync.subtitle.progress",
                defaultValue: "Writing one change at a time. FX Vault stays unlocked until the sync ends."
            )
        case .result:
            String(
                localized: "sync.subtitle.result",
                defaultValue: "Anything that did not sync stays pending for the next Sync."
            )
        }
    }
}

#Preview {
    if let dependencies = try? FeatureDependencies.preview() {
        SyncScreen(context: SyncContext(repositoryIDs: nil), dependencies: dependencies)
    }
}
