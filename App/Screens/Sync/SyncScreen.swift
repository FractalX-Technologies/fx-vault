import SwiftUI

/// The Sync sheet (§10 Sheets; boards Sync-Review, Sync-Delete, Sync-Progress, Sync-Done):
/// Summary → Deletions (live fetch) → Progress → Result. Holds a SyncActivity for the whole run
/// (``SyncViewModel``).
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
        Group {
            if let done = viewModel.done {
                SyncDoneView(done: done) { dismiss() }
            } else {
                steps
            }
        }
        .fxSheetBackground()
        .interactiveDismissDisabled(viewModel.blocksDismissal)
        .errorAlert($viewModel.alert)
        .task {
            // Only a sheet that has not loaded yet: a view model shown mid-run (previews, the
            // snapshots of boards Sync-Progress and Sync-Done) keeps its step.
            guard viewModel.step == .loading else { return }
            await viewModel.load()
        }
    }

    /// Every step but the short finish: the 1.0 dialog (boards Sync-Review, Sync-Progress,
    /// Sync-Delete): 22 pt inset, the compact title, the step, then the footer with no rule.
    private var steps: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Theme.Layout.compactSheetInset)
                .padding(.top, Theme.Layout.compactSheetInset)
                .padding(.bottom, Theme.Spacing.mediumMinus)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            SyncFooterView(
                buttons: viewModel.buttons,
                notice: footerNotice
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
    }

    /// No eyebrow on any step (the 1.0 boards): the title says it.
    private var header: some View {
        SheetHeader.dialog(title, subtitle: subtitle) {
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

    /// The summary's counts sit in the footer (board Sync-Review) unless a notice (offline) needs
    /// it. The deletions footer needs its width for three buttons.
    private var footerNotice: String? {
        if let notice = viewModel.footerNotice { return notice }
        return viewModel.step == .summary ? viewModel.summaryCountsLine : nil
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
            SyncRunView(viewModel: viewModel)
        case .result:
            SyncResultView(viewModel: viewModel)
        }
    }

    private var title: String {
        switch viewModel.step {
        case .deletions:
            viewModel.deletionTitle
        case .progress:
            SyncCopy.progressTitle
        case .result:
            viewModel.stopReason == nil
                ? String(localized: "sync.result.title", defaultValue: "Sync Finished")
                : String(localized: "sync.result.title.stopped", defaultValue: "Sync Stopped")
        case .summary, .loading, .failed:
            String(localized: "sync.title.summary", defaultValue: "Review Sync")
        }
    }

    private var subtitle: String {
        switch viewModel.step {
        case .loading, .failed:
            String(localized: "sync.subtitle.loading", defaultValue: "Pushes your vault's pending changes to GitHub.")
        case .summary:
            String(
                localized: "sync.subtitle.summary",
                defaultValue: "Names only · values go through gh and az, never shown"
            )
        case .deletions:
            SyncCopy.deletionSubtitle
        case .progress:
            SyncCopy.progressSubtitle
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
