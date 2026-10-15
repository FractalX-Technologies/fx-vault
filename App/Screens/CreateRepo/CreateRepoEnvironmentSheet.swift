import SwiftUI
import VaultCore

/// Adds or edits one staged environment (nested in New Repository): its name and deployment
/// branch policy, with the same `BranchPolicyEditorView` as Environment Settings.
struct CreateRepoEnvironmentSheet: View {
    @Bindable var editor: CreateRepoEnvironmentEditorViewModel
    let onCancel: () -> Void
    @FocusState private var isNameFocused: Bool

    var body: some View {
        ConfigEditorSheet(
            eyebrow: CreateRepoText.eyebrow,
            title: editor.isNew
                ? String(localized: "createRepo.environment.newTitle", defaultValue: "New Environment")
                : String(localized: "createRepo.environment.editTitle", defaultValue: "Edit Environment"),
            primaryTitle: editor.isNew
                ? String(localized: "createRepo.item.add", defaultValue: "Add")
                : String(localized: "createRepo.item.save", defaultValue: "Save"),
            isPrimaryEnabled: editor.canSave,
            isWorking: false,
            onCancel: onCancel,
            onPrimary: { editor.save() }
        ) {
            ConfigSheetField(String(localized: "createRepo.environment.name", defaultValue: "Name")) {
                EnvironmentNameField(
                    title: String(localized: "createRepo.environment.name", defaultValue: "Name"),
                    name: $editor.name,
                    prompt: "production",
                    isInvalid: editor.nameError != nil,
                    isFocused: $isNameFocused
                )
                if let error = editor.nameError {
                    ConfigEditorNoteView(note: .error(error))
                }
            }
            BranchPolicyEditorView(form: $editor.policyForm, isEnabled: true)
        }
    }
}
