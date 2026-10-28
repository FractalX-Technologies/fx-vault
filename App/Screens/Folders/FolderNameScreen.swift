import SwiftUI
import VaultCore

/// New Folder…, New Subfolder… and Rename… (v0.7.0). UI feature contract entry view: presented by `MainScreen`
/// for `MainSheet.folderName`.
struct FolderNameScreen: View {
    @State private var viewModel: FolderNameViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool

    init(context: FolderNameContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: FolderNameViewModel(context: context, dependencies: dependencies))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        ConfigEditorSheet(
            eyebrow: FolderCopy.eyebrow,
            title: viewModel.title,
            subtitle: viewModel.isRenaming ? nil : FolderCopy.emptyHint,
            primaryTitle: viewModel.primaryTitle,
            isPrimaryEnabled: viewModel.canSave,
            isWorking: viewModel.isSaving,
            onCancel: { dismiss() },
            onPrimary: save
        ) {
            ConfigSheetField(FolderCopy.nameField) {
                TextField(
                    FolderCopy.nameField,
                    text: $viewModel.name,
                    prompt: Text(verbatim: FolderCopy.namePrompt).foregroundStyle(Theme.Colors.subtleText)
                )
                .focused($isNameFocused)
                .accessibilityIdentifier(AccessibilityID.Main.folderName)
                .autocorrectionDisabled()
                .labelsHidden()
                .fxInputField(.rounded, isFocused: isNameFocused, isInvalid: viewModel.nameNote?.isError ?? false)
                .onSubmit(save)
                if let note = viewModel.nameNote {
                    ConfigEditorNoteView(note: note)
                }
            }
        }
        .onAppear { isNameFocused = true }
        .errorAlert($viewModel.alert)
    }

    private func save() {
        if viewModel.save() {
            dismiss()
        }
    }
}
