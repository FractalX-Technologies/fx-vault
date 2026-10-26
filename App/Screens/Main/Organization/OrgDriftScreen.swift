import SwiftUI
import VaultData

/// Refresh's findings for one organization (1.0 B7b; ``OrgDriftViewModel``): the drift review's
/// size, rows and delete confirmation, the names Refresh did not compare, and Done.
struct OrgDriftScreen: View {
    @State private var viewModel: OrgDriftViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: OrgDriftContext, dependencies: FeatureDependencies, onResolved: @escaping (Set<String>) -> Void) {
        _viewModel = State(initialValue: OrgDriftViewModel(context: context, dependencies: dependencies, onResolved: onResolved))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(spacing: 0) {
            SheetHeader(
                label: PlaceCopy.organization,
                title: DriftCopy.reviewTitle,
                subtitle: viewModel.login
            )
            .padding(.horizontal, Theme.Spacing.xxLarge)
            .padding(.top, Theme.Spacing.xxLarge)
            .padding(.bottom, Theme.Spacing.xLarge)
            ScrollView {
                if viewModel.rows.isEmpty {
                    Text(DriftCopy.nothingChanged)
                        .fxTextStyle(.callout)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
                        ConfigSheetList(viewModel.rows) { row in
                            DriftFindingRow(
                                row: row,
                                isResolving: viewModel.resolving.contains(row.id),
                                onChoose: { option in Task { await viewModel.choose(row.id, option) } },
                                onFillValue: { _ in }
                            )
                        }
                        DriftNotesField(notes: viewModel.notes)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.xxLarge)
            .padding(.bottom, Theme.Spacing.xLarge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HairlineDivider()
            ConfigSheetFooter(meta: nil, notice: viewModel.notice) {
                Button(String(localized: "common.done", defaultValue: "Done")) {
                    dismiss()
                }
                .fxButtonStyle(.primary, size: .large)
                .keyboardShortcut(.cancelAction)
            }
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
    }
}
