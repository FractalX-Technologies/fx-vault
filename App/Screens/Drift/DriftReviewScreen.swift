import SwiftUI
import VaultCore

/// DriftReviewScreen (§7.7): each finding with Keep Local / Accept GitHub.
///
/// UI feature contract entry view (ARCHITECTURE.md): presented by `MainScreen` for
/// `MainSheet.driftReview`. The init signature is fixed. Dismiss with `@Environment(\.dismiss)`.
struct DriftReviewScreen: View {
    @State private var viewModel: DriftReviewViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: DriftReviewContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: DriftReviewViewModel(context: context, dependencies: dependencies))
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
            footer
        }
        .driftSheetFrame()
        .fxSheetBackground()
        .errorAlert($viewModel.alert)
        .driftConfirmationDialog(viewModel.confirmation) {
            await viewModel.confirm()
        } cancel: {
            viewModel.cancelConfirmation()
        }
        .task {
            await viewModel.load()
        }
        .onDisappear {
            viewModel.finish()
        }
    }

    private var header: some View {
        SheetHeader(
            label: String(localized: "drift.review.eyebrow", defaultValue: "Drift review"),
            title: DriftCopy.reviewTitle,
            subtitle: subtitle
        ) {
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Label(String(localized: "drift.review.refresh", defaultValue: "Refresh"), systemImage: "arrow.clockwise")
            }
            .fxButtonStyle(.secondary)
            .disabled(viewModel.isLoading || !viewModel.isOnline)
            .help(viewModel.isOnline
                ? String(localized: "drift.review.refresh.help", defaultValue: "Check GitHub again")
                : ConnectivityCopy.offlineHelp)
        }
    }

    private var subtitle: String {
        let explanation = String(
            localized: "drift.review.subtitle",
            defaultValue: "Changed on GitHub since FX Vault last synced or checked. Keep your version or take GitHub's."
        )
        guard let fullName = viewModel.fullName else { return explanation }
        return "\(fullName) · \(explanation)"
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.report == nil {
            VStack(spacing: Theme.Spacing.small) {
                if viewModel.isLoading {
                    ProgressView()
                }
                Text(String(localized: "drift.review.loading", defaultValue: "Checking GitHub…"))
                    .fxTextStyle(.callout)
                    .foregroundStyle(Theme.Colors.mutedText)
            }
        } else if viewModel.rows.isEmpty, viewModel.notes.isEmpty {
            EmptyStateView(
                systemImage: "checkmark.circle",
                title: DriftCopy.nothingChanged,
                message: String(
                    localized: "drift.review.empty.message",
                    defaultValue: "Your vault matches what GitHub has for this repository."
                )
            ) {
                EmptyView()
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
                    if !viewModel.rows.isEmpty {
                        ConfigSheetList(viewModel.rows) { row in
                            DriftFindingRow(
                                row: row,
                                isResolving: viewModel.resolving.contains(row.id),
                                onChoose: { option in Task { await viewModel.choose(row.id, option) } },
                                onFillValue: { context in viewModel.fillValue(context) }
                            )
                        }
                    }
                    DriftNotesField(notes: viewModel.notes)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.xxLarge)
                .padding(.bottom, Theme.Spacing.xLarge)
            }
        }
    }

    private var footer: some View {
        ConfigSheetFooter(meta: viewModel.checkedAtText, notice: viewModel.notice) {
            Button(String(localized: "common.done", defaultValue: "Done")) {
                dismiss()
            }
            .fxButtonStyle(.primary, size: .large)
            .keyboardShortcut(.cancelAction)
        }
    }
}

#Preview {
    if let dependencies = try? FeatureDependencies.preview() {
        DriftReviewScreen(context: DriftReviewContext(repositoryID: RepoID()), dependencies: dependencies)
    }
}
