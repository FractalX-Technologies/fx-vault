import SwiftUI
import VaultCore

/// CopyToRepositoryScreen (v0.4.1): Copy To › Another Repository…. A search field, the vault's
/// repositories grouped by account, the chosen repository's scopes (read-only ones disabled with
/// the reason), then the outcome with Show.
///
/// UI feature contract entry view (ARCHITECTURE.md): presented by `MainScreen` for
/// `MainSheet.copyToRepository`. The init signature is fixed. Dismiss with
/// `@Environment(\.dismiss)`.
struct CopyToRepositoryScreen: View {
    @State private var viewModel: CopyToRepositoryViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isSearchFocused: Bool

    init(context: CopyToRepositoryContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: CopyToRepositoryViewModel(context: context, dependencies: dependencies))
    }

    /// A screen over an existing view model (previews and snapshots).
    init(viewModel: CopyToRepositoryViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        ConfigEditorSheet(
            eyebrow: String(localized: "copyTo.eyebrow", defaultValue: "Copy To"),
            title: String(localized: "copyTo.title", defaultValue: "Another Repository"),
            subtitle: viewModel.subtitle,
            primaryTitle: viewModel.result == nil
                ? String(localized: "copyTo.copy", defaultValue: "Copy")
                : String(localized: "common.done", defaultValue: "Done"),
            isPrimaryEnabled: viewModel.result != nil || viewModel.canCopy,
            isWorking: viewModel.isCopying,
            onCancel: { dismiss() },
            onPrimary: primary
        ) {
            if let error = viewModel.loadError {
                Banner(.danger, message: error.message)
            } else if !viewModel.isLoaded {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            } else if let notice = viewModel.resultNotice, let target = viewModel.selectedTarget {
                Banner(.info, message: notice, action: .init(
                    title: String(localized: "copyTo.show", defaultValue: "Show \(target.title)")
                ) {
                    viewModel.showTarget()
                    dismiss()
                })
            } else {
                ConfigSheetField(String(localized: "copyTo.search", defaultValue: "Repository")) {
                    TextField(
                        String(localized: "copyTo.search", defaultValue: "Repository"),
                        text: $viewModel.searchText,
                        prompt: Text(String(localized: "copyTo.search.prompt", defaultValue: "Search by name, owner or account"))
                            .foregroundStyle(Theme.Colors.subtleText)
                    )
                    .focused($isSearchFocused)
                    .autocorrectionDisabled()
                    .labelsHidden()
                    .fxInputField(.rounded, isFocused: isSearchFocused)
                    CopyRepositoryList(viewModel: viewModel)
                }
            }
        }
        .task {
            await viewModel.load()
            isSearchFocused = true
        }
        .errorAlert($viewModel.alert)
        .confirmationDialog(
            viewModel.pendingCopy?.title ?? "",
            isPresented: copyBinding,
            titleVisibility: .visible,
            presenting: viewModel.pendingCopy
        ) { request in
            Button(request.replaceTitle) {
                viewModel.confirm(replacing: true)
            }
            Button(String(localized: "main.detail.copy.conflict.keep", defaultValue: "Keep Existing")) {
                viewModel.confirm(replacing: false)
            }
            Button(String(localized: "main.detail.copy.conflict.cancel", defaultValue: "Cancel"), role: .cancel) {
                viewModel.pendingCopy = nil
            }
        } message: { request in
            Text(request.message)
        }
    }

    private var copyBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingCopy != nil },
            set: { if !$0 { viewModel.pendingCopy = nil } }
        )
    }

    private func primary() {
        if viewModel.result != nil {
            dismiss()
        } else {
            viewModel.copy()
        }
    }
}

/// The repositories by account; the chosen one lists its scopes underneath.
private struct CopyRepositoryList: View {
    let viewModel: CopyToRepositoryViewModel

    var body: some View {
        let sections = viewModel.sections
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                if sections.isEmpty {
                    Text(String(localized: "copyTo.empty", defaultValue: "No repository matches."))
                        .fxTextStyle(.caption)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .padding(Theme.Spacing.medium)
                }
                ForEach(sections) { section in
                    SectionLabel(section.accountLogin)
                        .padding(.top, Theme.Spacing.small)
                        .padding(.horizontal, Theme.Spacing.small)
                    ForEach(section.repositories, id: \.id) { repository in
                        repositoryRow(repository)
                        if viewModel.selectedRepositoryID == repository.id {
                            scopeRows
                        }
                    }
                }
            }
            .padding(Theme.Spacing.xSmall)
        }
        .frame(height: Theme.Layout.copyTargetListHeight)
        .fxCardBackground(.container)
    }

    private func repositoryRow(_ repository: RepoModel) -> some View {
        Button {
            viewModel.select(repository)
        } label: {
            HStack(spacing: Theme.Spacing.mediumMinus) {
                Image(systemName: viewModel.selectedRepositoryID == repository.id ? "chevron.down" : "chevron.right")
                    .font(Theme.Typography.monoLabel)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .accessibilityHidden(true)
                Text(verbatim: repository.fullName)
                    .fxTextStyle(.monoName)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fxRowBackground(isSelected: viewModel.selectedRepositoryID == repository.id, style: .sidebar)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var scopeRows: some View {
        if viewModel.targets.isEmpty {
            Text(String(localized: "copyTo.noScope", defaultValue: "No other scope to copy into."))
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
                .padding(.leading, Theme.Spacing.xxLarge)
                .padding(.vertical, Theme.Spacing.xSmall)
        }
        ForEach(viewModel.targets) { row in
            let isSelected = viewModel.selectedTargetID == row.id
            Button {
                viewModel.selectedTargetID = row.id
            } label: {
                HStack(spacing: Theme.Spacing.mediumMinus) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? Theme.Colors.brand : Theme.Colors.subtleText)
                        .accessibilityHidden(true)
                    Text(row.scopeTitle)
                        .fxTextStyle(.callout)
                        .foregroundStyle(row.target.isEditable ? Theme.Colors.ink : Theme.Colors.subtleText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let reason = row.readOnlyReason {
                        Image(systemName: "lock")
                            .foregroundStyle(Theme.Colors.subtleText)
                            .help(reason.localizedExplanation)
                            .accessibilityLabel(reason.localizedExplanation)
                    }
                }
                .padding(.leading, Theme.Spacing.xxLarge)
                .padding(.trailing, Theme.Spacing.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fxRowBackground(isSelected: isSelected, style: .scope)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!row.target.isEditable)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

#Preview {
    if let dependencies = try? FeatureDependencies.preview() {
        CopyToRepositoryScreen(
            context: CopyToRepositoryContext(itemIDs: [], sourceRepositoryID: RepoID(), sourceScope: .repository),
            dependencies: dependencies
        )
    }
}
