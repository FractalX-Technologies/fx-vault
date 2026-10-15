import SwiftUI

/// "Add repository by name…" for one account (§10 Column 1).
struct AddRepositorySheet: View {
    @State private var viewModel: AddRepositoryViewModel
    @Environment(\.dismiss) private var dismiss

    init(viewModel: AddRepositoryViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            CardHeader(
                systemImage: "plus.magnifyingglass",
                title: String(localized: "main.addRepo.title", defaultValue: "Add Repository by Name"),
                subtitle: String(
                    localized: "main.addRepo.subtitle",
                    defaultValue: "For repositories \(viewModel.accountLogin) reaches as a collaborator, which GitHub CLI cannot list."
                )
            )
            TextField(
                String(localized: "main.addRepo.field", defaultValue: "owner/name"),
                text: $viewModel.fullName
            )
            .textFieldStyle(.roundedBorder)
            .font(Theme.Typography.monospaced)
            .autocorrectionDisabled()
            .onSubmit(add)
            if let error = viewModel.error {
                InlineErrorView(error: error)
            }
            if !viewModel.isOnline {
                Label(ConnectivityCopy.offlineHelp, systemImage: ConnectivityBannerModel.offline.systemImage)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if viewModel.isChecking {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(String(localized: "main.addRepo.submit", defaultValue: "Add"), action: add)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canAdd)
            }
        }
        .padding(Theme.Spacing.xLarge)
        .frame(width: Theme.Layout.sheetWidth)
    }

    private func add() {
        Task {
            if await viewModel.add() {
                dismiss()
            }
        }
    }
}
