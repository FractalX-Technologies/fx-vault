import SwiftUI
import VaultCore

/// New Environment (board NewEnvironment): the name (fold-key availability) and the deployment
/// branch policy in the dialog form, staged with `ConfigRepository.createEnvironment(in:name:policy:)`;
/// the next Sync creates it on GitHub.
///
/// UI feature contract entry view (ARCHITECTURE.md): presented by `MainScreen` for
/// `MainSheet.newEnvironment`. The init signature is fixed. Dismiss with `@Environment(\.dismiss)`.
struct NewEnvironmentScreen: View {
    @State private var viewModel: NewEnvironmentViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool

    init(context: NewEnvironmentContext, dependencies: FeatureDependencies) {
        self.init(viewModel: NewEnvironmentViewModel(context: context, dependencies: dependencies))
    }

    /// Over a prepared view model (snapshots of board NewEnvironment).
    init(viewModel: NewEnvironmentViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        DialogSheet(
            title: viewModel.title,
            footerNote: SyncCopy.createdAtNextSync,
            isWorking: viewModel.isSaving
        ) {
            if let error = viewModel.loadError {
                Banner(.danger, message: error.message)
            } else {
                if let reason = viewModel.readOnlyReason {
                    Banner(.warning, message: reason.localizedExplanation, systemImage: "lock")
                }
                let nameTitle = String(localized: "environment.name", defaultValue: "Name")
                DialogFormRow(nameTitle) {
                    EnvironmentNameField(
                        title: nameTitle,
                        name: $viewModel.name,
                        prompt: "staging",
                        isInvalid: viewModel.nameStatus.note?.isError ?? false,
                        isFocused: $isNameFocused,
                        shape: .dialog
                    )
                    .disabled(!viewModel.canEdit)
                    if let note = viewModel.nameNote {
                        DialogFormNote(note.message, tone: note.dialogTone)
                    }
                }
                DialogFormRow(BranchPolicyEditorView.formLabel) {
                    BranchPolicyEditorView(form: $viewModel.policy, isEnabled: viewModel.canEdit)
                    if viewModel.showsPlanNote {
                        EnvironmentPlanNoteView(isPlanGated: viewModel.isPlanGated)
                    }
                }
            }
        } actions: {
            Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                dismiss()
            }
            .fxButtonStyle(.outline, size: .dialog)
            .keyboardShortcut(.cancelAction)
            Button(String(localized: "environment.new.stage", defaultValue: "Stage Environment"), action: create)
                .fxButtonStyle(.primary, size: .dialog)
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canCreate)
        }
        .frame(width: Theme.Layout.newEnvironmentSheetWidth)
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
