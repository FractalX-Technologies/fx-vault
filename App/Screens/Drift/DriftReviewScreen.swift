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
        .frame(
            minWidth: Theme.Layout.driftSheetWidth,
            idealWidth: Theme.Layout.driftSheetWidth,
            maxWidth: Theme.Layout.driftSheetWidth,
            minHeight: Theme.Layout.driftSheetMinHeight,
            idealHeight: Theme.Layout.driftSheetIdealHeight
        )
        .fxSheetBackground()
        .errorAlert($viewModel.alert)
        .confirmationDialog(
            viewModel.confirmation?.title ?? "",
            isPresented: Binding(
                get: { viewModel.confirmation != nil },
                set: { if !$0 { viewModel.cancelConfirmation() } }
            ),
            presenting: viewModel.confirmation
        ) { _ in
            Button(DriftCopy.confirmDelete, role: .destructive) {
                Task { await viewModel.confirm() }
            }
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {
                viewModel.cancelConfirmation()
            }
        } message: { confirmation in
            Text(confirmation.message)
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
            title: String(localized: "drift.review.title", defaultValue: "Changes on GitHub"),
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
                title: String(localized: "drift.review.empty.title", defaultValue: "Nothing changed on GitHub"),
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
                    if !viewModel.notes.isEmpty {
                        ConfigSheetField(String(localized: "drift.review.notes", defaultValue: "Not compared")) {
                            ForEach(viewModel.notes, id: \.self) { note in
                                Label {
                                    Text(verbatim: note)
                                        .fxTextStyle(.callout)
                                        .foregroundStyle(Theme.Colors.mutedText)
                                        .fixedSize(horizontal: false, vertical: true)
                                } icon: {
                                    Image(systemName: "eye.slash")
                                        .foregroundStyle(Theme.Colors.subtleText)
                                }
                            }
                        }
                    }
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
