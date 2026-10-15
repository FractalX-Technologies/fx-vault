import SwiftUI
import VaultCore

/// RenameEnvironmentScreen (`ConfigRepository.renameEnvironment(_:to:)`, §7.6, D20): local or
/// case-only renames, and the guided recreate of a synced environment, blocked with "Enter
/// Values" while any secret value is missing.
///
/// UI feature contract entry view (ARCHITECTURE.md): presented by `MainScreen` for
/// `MainSheet.renameEnvironment`. The init signature is fixed. Dismiss with
/// `@Environment(\.dismiss)`.
struct RenameEnvironmentScreen: View {
    @State private var viewModel: RenameEnvironmentViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool

    init(context: EnvironmentContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: RenameEnvironmentViewModel(context: context, dependencies: dependencies))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        ConfigEditorSheet(
            eyebrow: String(localized: "environment.sheet.eyebrow", defaultValue: "Environment"),
            title: String(localized: "environment.rename.title", defaultValue: "Rename Environment"),
            subtitle: viewModel.subtitle,
            primaryTitle: String(localized: "environment.rename.submit", defaultValue: "Rename"),
            isPrimaryEnabled: viewModel.canRename,
            isWorking: viewModel.isSaving,
            onCancel: { dismiss() },
            onPrimary: rename
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
                ConfigSheetField(String(localized: "environment.rename.field", defaultValue: "New name")) {
                    EnvironmentNameField(
                        title: String(localized: "environment.rename.field", defaultValue: "New name"),
                        name: $viewModel.name,
                        prompt: nil,
                        isInvalid: viewModel.nameStatus.note?.isError ?? false,
                        isFocused: $isNameFocused
                    )
                    .disabled(!viewModel.canEdit)
                    if let note = viewModel.nameStatus.note, viewModel.nameStatus != .available {
                        ConfigEditorNoteView(note: note)
                    }
                    if let note = viewModel.kindNote {
                        ConfigEditorNoteView(note: note)
                    }
                }
                if let note = viewModel.missingValuesNote {
                    VStack(alignment: .leading, spacing: Theme.Spacing.mediumMinus) {
                        ConfigEditorNoteView(note: note)
                        Button(String(localized: "environment.rename.enterValues", defaultValue: "Enter Values…")) {
                            viewModel.enterValues()
                        }
                        .fxButtonStyle(.outline)
                    }
                    .configSheetRowPadding()
                    .fxCardBackground(.container)
                }
            }
        }
        .task { await viewModel.load() }
        .errorAlert($viewModel.alert)
    }

    private func rename() {
        if viewModel.rename() {
            dismiss()
        }
    }
}

#Preview {
    if let dependencies = try? FeatureDependencies.preview() {
        RenameEnvironmentScreen(
            context: EnvironmentContext(repositoryID: RepoID(), environmentID: EnvironmentID()),
            dependencies: dependencies
        )
    }
}
