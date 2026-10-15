import SwiftUI

/// "Add repository by name…" for one account (§10 Column 1), in the sheet pattern of
/// docs/DESIGN.md: section label, title, muted line, a mono field and pill buttons.
struct AddRepositorySheet: View {
    @State private var viewModel: AddRepositoryViewModel
    @Environment(\.dismiss) private var dismiss

    init(viewModel: AddRepositoryViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionLabel(viewModel.accountLogin)
                Text(String(localized: "main.addRepo.title", defaultValue: "Add Repository by Name"))
                    .fxTextStyle(.title)
                    .foregroundStyle(Theme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(
                    localized: "main.addRepo.subtitle",
                    defaultValue: "For repositories \(viewModel.accountLogin) reaches as a collaborator, which GitHub CLI cannot list."
                ))
                .fxTextStyle(.body)
                .foregroundStyle(Theme.Colors.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            }
            FXTextField(
                label: String(localized: "main.addRepo.fieldLabel", defaultValue: "Repository"),
                text: $viewModel.fullName,
                prompt: String(localized: "main.addRepo.field", defaultValue: "owner/name"),
                isInvalid: viewModel.error != nil,
                isMonospaced: true
            )
            .autocorrectionDisabled()
            .onSubmit(add)
            if let error = viewModel.error {
                InlineErrorView(error: error)
            }
            if !viewModel.isOnline {
                Label(ConnectivityCopy.offlineHelp, systemImage: ConnectivityBannerModel.offline.systemImage)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Spacing.mediumMinus) {
                if viewModel.isChecking {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    dismiss()
                }
                .fxButtonStyle(.secondary, size: .large)
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "main.addRepo.submit", defaultValue: "Add"), action: add)
                    .fxButtonStyle(.primary, size: .large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canAdd)
            }
        }
        .padding(Theme.Spacing.xxLarge)
        .frame(width: Theme.Layout.sheetWidth)
        .fxSheetBackground()
    }

    private func add() {
        Task {
            if await viewModel.add() {
                dismiss()
            }
        }
    }
}
