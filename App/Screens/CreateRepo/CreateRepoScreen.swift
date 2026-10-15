import SwiftUI

/// New Repository (⌘N, §10 `CreateRepoScreen`): owner, name with a live availability check,
/// description, visibility, README, `.gitignore` and license templates, staged environments,
/// secrets and variables, and Clone to my Mac. Create stages everything in the vault; the next
/// Sync creates it on GitHub.
///
/// UI feature contract entry view (ARCHITECTURE.md): presented by `MainScreen` for
/// `MainSheet.createRepository`. The init signature is fixed.
struct CreateRepoScreen: View {
    @State private var viewModel: CreateRepoViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: CreateRepoContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: CreateRepoViewModel(context: context, dependencies: dependencies))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        content
            .frame(width: Theme.Layout.createRepoSheetWidth)
            .task {
                await viewModel.load()
            }
            .errorAlert($viewModel.alert)
            .sheet(item: editorBinding) { route in
                switch route {
                case .item(let editor):
                    CreateRepoItemSheet(editor: editor) {
                        viewModel.dismissEditor()
                    }
                case .environment(let editor):
                    CreateRepoEnvironmentSheet(editor: editor) {
                        viewModel.dismissEditor()
                    }
                }
            }
            .confirmationDialog(
                String(localized: "createRepo.discard.title", defaultValue: "Discard this repository?"),
                isPresented: $viewModel.isConfirmingDiscard,
                titleVisibility: .visible
            ) {
                Button(String(localized: "createRepo.discard.confirm", defaultValue: "Discard"), role: .destructive) {
                    viewModel.discard()
                    dismiss()
                }
                Button(String(localized: "createRepo.discard.keepEditing", defaultValue: "Keep Editing"), role: .cancel) {}
            } message: {
                Text(String(
                    localized: "createRepo.discard.message",
                    defaultValue: "The name, environments, secrets and variables you entered are not kept."
                ))
            }
    }

    @ViewBuilder private var content: some View {
        switch viewModel.phase {
        case .loading:
            loadingView
        case .loadFailed(let error):
            EmptyStateView(systemImage: "exclamationmark.triangle", title: error.title, message: error.message) {
                HStack {
                    Button(String(localized: "common.close", defaultValue: "Close")) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button(String(localized: "createRepo.retry", defaultValue: "Try Again")) {
                        Task { await viewModel.load() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .frame(height: Theme.Layout.createRepoStatusHeight)
        case .ready, .staging:
            CreateRepoFormView(viewModel: viewModel, onCancel: cancel, onCreate: create)
        case .staged(let staged):
            CreateRepoStagedView(
                staged: staged,
                canSyncNow: viewModel.canSyncNow,
                syncNowUnavailableReason: viewModel.syncNowUnavailableReason
            ) {
                viewModel.syncNow()
            } onDone: {
                dismiss()
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: Theme.Spacing.medium) {
            ProgressView()
                .controlSize(.small)
            Text(String(localized: "createRepo.loading", defaultValue: "Loading accounts and organizations…"))
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.textSecondary)
            Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.Layout.createRepoStatusHeight)
    }

    /// Closing the nested editor from outside (Escape, a lock) drops what it holds.
    private var editorBinding: Binding<CreateRepoEditorRoute?> {
        Binding(
            get: { viewModel.editor },
            set: { route in
                if route == nil {
                    viewModel.dismissEditor()
                }
            }
        )
    }

    private func cancel() {
        if viewModel.requestCancel() {
            dismiss()
        }
    }

    private func create() {
        Task {
            await viewModel.create()
        }
    }
}

#Preview {
    if let dependencies = try? FeatureDependencies.preview() {
        CreateRepoScreen(context: CreateRepoContext(accountLogin: nil, ownerLogin: nil), dependencies: dependencies)
    }
}
