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
    @FocusState private var isNameFocused: Bool

    init(context: NewEnvironmentContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: NewEnvironmentViewModel(context: context, dependencies: dependencies))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        ConfigEditorSheet(
            eyebrow: String(localized: "environment.sheet.eyebrow", defaultValue: "Environment"),
            title: String(localized: "environment.new.title", defaultValue: "New Environment"),
            subtitle: viewModel.subtitle,
            primaryTitle: String(localized: "environment.new.create", defaultValue: "Create"),
            isPrimaryEnabled: viewModel.canCreate,
            isWorking: viewModel.isSaving,
            onCancel: { dismiss() },
            onPrimary: create
        ) {
            if let error = viewModel.loadError {
                Banner(.danger, message: error.message)
            } else {
                if let reason = viewModel.readOnlyReason {
                    Banner(.warning, message: reason.localizedExplanation, systemImage: "lock")
                }
                ConfigSheetField(String(localized: "environment.name", defaultValue: "Name")) {
                    EnvironmentNameField(
                        title: String(localized: "environment.name", defaultValue: "Name"),
                        name: $viewModel.name,
                        prompt: "staging",
                        isInvalid: viewModel.nameStatus.note?.isError ?? false,
                        isFocused: $isNameFocused
                    )
                    .disabled(!viewModel.canEdit)
                    if let note = viewModel.nameStatus.note {
                        ConfigEditorNoteView(note: note)
                    }
                }
                BranchPolicyEditorView(form: $viewModel.policy, isEnabled: viewModel.canEdit)
                if viewModel.showsPlanNote {
                    EnvironmentPlanNoteView(isPlanGated: viewModel.isPlanGated)
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
