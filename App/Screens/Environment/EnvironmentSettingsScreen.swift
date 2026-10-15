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
            eyebrow: String(localized: "environment.sheet.eyebrow", defaultValue: "Environment"),
            title: viewModel.title,
            subtitle: viewModel.subtitle,
            primaryTitle: String(localized: "environment.settings.save", defaultValue: "Save"),
            isPrimaryEnabled: viewModel.canSave,
            isWorking: viewModel.isSaving,
            onCancel: { dismiss() },
            onPrimary: save
        ) {
            if let error = viewModel.loadError {
                Banner(.danger, message: error.message)
            } else if let environment = viewModel.environment {
                if let reason = viewModel.readOnlyReason {
                    Banner(.warning, message: reason.localizedExplanation, systemImage: "lock")
                }
                ConfigSheetField(String(localized: "environment.name", defaultValue: "Name")) {
                    HStack(spacing: Theme.Spacing.small) {
                        Text(environment.name)
                            .fxTextStyle(.mono)
                            .foregroundStyle(Theme.Colors.ink)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(String(localized: "environment.settings.rename", defaultValue: "Rename…")) {
                            viewModel.rename()
                        }
                        .fxButtonStyle(.outline)
                        .disabled(!viewModel.canEdit)
                    }
                    .padding(.leading, Theme.Spacing.large)
                    .padding(.trailing, Theme.Spacing.xSmall)
                    .frame(minHeight: Theme.Layout.inputHeight)
                    .fxCardBackground(.container)
                    if let note = viewModel.syncNote {
                        ConfigEditorNoteView(note: note)
                    }
                    if let note = viewModel.foreignRulesNote {
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
