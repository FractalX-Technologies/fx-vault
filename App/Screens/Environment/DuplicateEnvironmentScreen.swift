import SwiftUI
import VaultCore

/// DuplicateEnvironmentScreen (`ConfigRepository.duplicateEnvironment(_:as:)`): target name with
/// fold-key availability; the policy and every value are copied, value-missing secrets stay
/// value-missing.
///
/// UI feature contract entry view (ARCHITECTURE.md): presented by `MainScreen` for
/// `MainSheet.duplicateEnvironment`. The init signature is fixed. Dismiss with
/// `@Environment(\.dismiss)`.
struct DuplicateEnvironmentScreen: View {
    @State private var viewModel: DuplicateEnvironmentViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool

    init(context: EnvironmentContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: DuplicateEnvironmentViewModel(context: context, dependencies: dependencies))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        ConfigEditorSheet(
            eyebrow: String(localized: "environment.sheet.eyebrow", defaultValue: "Environment"),
            title: String(localized: "environment.duplicate.title", defaultValue: "Duplicate Environment"),
            subtitle: viewModel.subtitle,
            primaryTitle: String(localized: "environment.duplicate.submit", defaultValue: "Duplicate"),
            isPrimaryEnabled: viewModel.canDuplicate,
            isWorking: viewModel.isSaving,
            onCancel: { dismiss() },
            onPrimary: duplicate
        ) {
            if let error = viewModel.loadError {
                Banner(.danger, message: error.message)
            } else if !viewModel.isLoaded {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            } else {
                if let reason = viewModel.readOnlyReason {
                    Banner(.warning, message: reason.localizedExplanation, systemImage: "lock")
                }
                ConfigSheetField(String(localized: "environment.duplicate.field", defaultValue: "New environment name")) {
                    EnvironmentNameField(
                        title: String(localized: "environment.duplicate.field", defaultValue: "New environment name"),
                        name: $viewModel.name,
                        prompt: "production",
                        isInvalid: viewModel.nameStatus.note?.isError ?? false,
                        isFocused: $isNameFocused
                    )
                    .disabled(!viewModel.canEdit)
                    if let note = viewModel.nameStatus.note {
                        ConfigEditorNoteView(note: note)
                    }
                }
                if viewModel.summary != nil || viewModel.valueMissingNote != nil {
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        if let summary = viewModel.summary {
                            ConfigEditorNoteView(note: .info(summary))
                        }
                        if let note = viewModel.valueMissingNote {
                            ConfigEditorNoteView(note: note)
                        }
                    }
                    .configSheetRowPadding()
                    .fxCardBackground(.container)
                }
            }
        }
        .task { await viewModel.load() }
        .errorAlert($viewModel.alert)
    }

    private func duplicate() {
        if viewModel.duplicate() {
            dismiss()
        }
    }
}

#Preview {
    if let dependencies = try? FeatureDependencies.preview() {
        DuplicateEnvironmentScreen(
            context: EnvironmentContext(repositoryID: RepoID(), environmentID: EnvironmentID()),
            dependencies: dependencies
        )
    }
}
