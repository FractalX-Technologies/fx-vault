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

    init(context: EnvironmentContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: DuplicateEnvironmentViewModel(context: context, dependencies: dependencies))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        ConfigEditorSheet(
            title: String(localized: "environment.duplicate.title", defaultValue: "Duplicate Environment"),
            subtitle: viewModel.subtitle,
            primaryTitle: String(localized: "environment.duplicate.submit", defaultValue: "Duplicate"),
            isPrimaryEnabled: viewModel.canDuplicate,
            isWorking: viewModel.isSaving,
            onCancel: { dismiss() },
            onPrimary: duplicate
        ) {
            if let error = viewModel.loadError {
                Section {
                    ConfigEditorNoteView(note: .error(error.message))
                }
            } else if !viewModel.isLoaded {
                Section {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                }
            } else {
                if let reason = viewModel.readOnlyReason {
                    Section {
                        ConfigEditorNoteView(note: .warning(reason.localizedExplanation))
                    }
                }
                Section {
                    TextField(
                        String(localized: "environment.duplicate.field", defaultValue: "New environment name"),
                        text: $viewModel.name,
                        prompt: Text(verbatim: "production")
                    )
                    .autocorrectionDisabled()
                    .disabled(!viewModel.canEdit)
                    if let note = viewModel.nameStatus.note {
                        ConfigEditorNoteView(note: note)
                    }
                }
                Section {
                    if let summary = viewModel.summary {
                        ConfigEditorNoteView(note: .info(summary))
                    }
                    if let note = viewModel.valueMissingNote {
                        ConfigEditorNoteView(note: note)
                    }
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
