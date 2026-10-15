import SwiftUI
import VaultCore

/// "+ New Environment": name (fold-key availability) and deployment branch policy, created with
/// `ConfigRepository.createEnvironment(in:name:policy:)`.
///
/// UI feature contract entry view (ARCHITECTURE.md): presented by `MainScreen` for
/// `MainSheet.newEnvironment`. The init signature is fixed. Dismiss with `@Environment(\.dismiss)`.
struct NewEnvironmentScreen: View {
    @State private var viewModel: NewEnvironmentViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: NewEnvironmentContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: NewEnvironmentViewModel(context: context, dependencies: dependencies))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        ConfigEditorSheet(
            title: String(localized: "environment.new.title", defaultValue: "New Environment"),
            subtitle: viewModel.subtitle,
            primaryTitle: String(localized: "environment.new.create", defaultValue: "Create"),
            isPrimaryEnabled: viewModel.canCreate,
            isWorking: viewModel.isSaving,
            onCancel: { dismiss() },
            onPrimary: create
        ) {
            if let error = viewModel.loadError {
                Section {
                    ConfigEditorNoteView(note: .error(error.message))
                }
            } else {
                if let reason = viewModel.readOnlyReason {
                    Section {
                        ConfigEditorNoteView(note: .warning(reason.localizedExplanation))
                    }
                }
                Section {
                    TextField(
                        String(localized: "environment.name", defaultValue: "Name"),
                        text: $viewModel.name,
                        prompt: Text(verbatim: "staging")
                    )
                    .autocorrectionDisabled()
                    .disabled(!viewModel.canEdit)
                    if let note = viewModel.nameStatus.note {
                        ConfigEditorNoteView(note: note)
                    }
                }
                BranchPolicyEditorView(form: $viewModel.policy, isEnabled: viewModel.canEdit)
                if viewModel.showsPlanNote {
                    Section {
                        EnvironmentPlanNoteView(isPlanGated: viewModel.isPlanGated)
                    }
                }
            }
        }
        .errorAlert($viewModel.alert)
    }

    private func create() {
        if viewModel.create() {
            dismiss()
        }
    }
}

#Preview {
    if let dependencies = try? FeatureDependencies.preview() {
        NewEnvironmentScreen(context: NewEnvironmentContext(repositoryID: RepoID()), dependencies: dependencies)
    }
}
