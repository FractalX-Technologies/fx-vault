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

    /// Shows an existing view model (previews and the visual snapshot tests).
    init(viewModel: SyncViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Theme.Spacing.xxLarge)
                .padding(.top, Theme.Spacing.xxLarge)
                .padding(.bottom, Theme.Spacing.xLarge)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HairlineDivider()
            SyncFooterView(
                buttons: viewModel.buttons,
                notice: viewModel.footerNotice,
                meta: footerMeta
            ) { action in
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
        .fxSheetBackground()
        .interactiveDismissDisabled(viewModel.blocksDismissal)
        .errorAlert($viewModel.alert)
        .confirmationDialog(
            viewModel.pendingTakeover.map { SyncCopy.takeOverTitle($0.login) } ?? "",
            isPresented: Binding(
                get: { viewModel.pendingTakeover != nil },
                set: { if !$0 { viewModel.pendingTakeover = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(SyncCopy.takeOverConfirm, role: .destructive) {
                Task { await viewModel.confirmTakeover() }
            }
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {
                viewModel.pendingTakeover = nil
            }
        } message: {
            Text(SyncCopy.takeOverMessage)
        }
        .task {
            await viewModel.load()
        }
    }

    private var header: some View {
        SheetHeader(label: eyebrow, title: title, subtitle: subtitle) {
            if viewModel.step == .summary || viewModel.step == .result {
                Button {
                    viewModel.copySummary()
                } label: {
                    Label(String(localized: "sync.copyReport", defaultValue: "Copy as Text"), systemImage: "doc.on.doc")
                }
                .fxButtonStyle(.ghost)
                .help(String(
                    localized: "sync.copyReport.help",
                    defaultValue: "Copy the names and counts as plain text. Values are never included."
                ))
            }
        }
    }

    /// The write limit sits in the footer of the summary (board SyncReview); the progress step
    /// shows it under the bar. The deletions footer needs its width for three pills.
    private var footerMeta: String? {
        switch viewModel.step {
        case .summary: viewModel.writeBudgetLine
        case .loading, .failed, .deletions, .progress, .result: nil
        }
    }

    private var eyebrow: String {
        switch viewModel.step {
        case .loading, .failed, .summary, .deletions:
            String(localized: "sync.eyebrow.review", defaultValue: "Review before sync")
        case .progress, .result:
            String(localized: "sync.eyebrow.run", defaultValue: "Sync")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.step {
        case .loading:
            VStack(spacing: Theme.Spacing.small) {
                ProgressView()
                Text(String(localized: "sync.loading", defaultValue: "Checking what GitHub has…"))
                    .fxTextStyle(.callout)
                    .foregroundStyle(Theme.Colors.mutedText)
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
        case .summary:
            if viewModel.repositories.count == 1, let repository = viewModel.repositories.first {
                String(localized: "sync.title.repository", defaultValue: "Sync to \(repository.fullName)")
            } else {
                String(localized: "sync.title", defaultValue: "Sync")
            }
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
