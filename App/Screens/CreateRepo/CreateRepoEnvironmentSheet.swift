import SwiftUI
import VaultCore

/// Adds or edits one staged environment (nested in New Repository): its name and deployment
/// branch policy, with the same `BranchPolicyEditorView` as Environment Settings.
struct CreateRepoEnvironmentSheet: View {
    @Bindable var editor: CreateRepoEnvironmentEditorViewModel
    let onCancel: () -> Void

    var body: some View {
        ConfigEditorSheet(
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
            Section {
                TextField(
                    String(localized: "createRepo.environment.name", defaultValue: "Name"),
                    text: $editor.name,
                    prompt: Text(verbatim: "production")
                )
                .autocorrectionDisabled()
                if let error = editor.nameError {
                    ConfigEditorNoteView(note: .error(error))
                }
            }
            BranchPolicyEditorView(form: $editor.policyForm, isEnabled: true)
        }
    }
}
