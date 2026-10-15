import SwiftUI
import VaultCore

/// EnvironmentSettingsScreen: name (Rename… opens `RenameEnvironmentScreen`) and the
/// `BranchPolicyEditor` (All branches / Protected branches only / Selected patterns), with the
/// paid-plan note.
///
/// UI feature contract entry view (ARCHITECTURE.md): presented by `MainScreen` for
/// `MainSheet.environmentSettings`. The init signature is fixed. Dismiss with
/// `@Environment(\.dismiss)`.
struct EnvironmentSettingsScreen: View {
    @State private var viewModel: EnvironmentSettingsViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: EnvironmentContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: EnvironmentSettingsViewModel(context: context, dependencies: dependencies))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        ConfigEditorSheet(
            title: viewModel.title,
            subtitle: viewModel.subtitle,
            primaryTitle: String(localized: "environment.settings.save", defaultValue: "Save"),
            isPrimaryEnabled: viewModel.canSave,
            isWorking: viewModel.isSaving,
            onCancel: { dismiss() },
            onPrimary: save
        ) {
            if let error = viewModel.loadError {
                Section {
                    ConfigEditorNoteView(note: .error(error.message))
                }
            } else if let environment = viewModel.environment {
                if let reason = viewModel.readOnlyReason {
                    Section {
                        ConfigEditorNoteView(note: .warning(reason.localizedExplanation))
                    }
                }
                Section {
                    LabeledContent(String(localized: "environment.name", defaultValue: "Name")) {
                        HStack(spacing: Theme.Spacing.small) {
                            Text(environment.name)
                                .textSelection(.enabled)
                            Button(String(localized: "environment.settings.rename", defaultValue: "Rename…")) {
                                viewModel.rename()
                            }
                            .controlSize(.small)
                            .disabled(!viewModel.canEdit)
                        }
                    }
                    if let note = viewModel.syncNote {
                        ConfigEditorNoteView(note: note)
                    }
                    if let note = viewModel.foreignRulesNote {
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

    private func save() {
        if viewModel.save() {
            dismiss()
        }
    }
}

#Preview {
    if let dependencies = try? FeatureDependencies.preview() {
        EnvironmentSettingsScreen(
            context: EnvironmentContext(repositoryID: RepoID(), environmentID: EnvironmentID()),
            dependencies: dependencies
        )
    }
}
