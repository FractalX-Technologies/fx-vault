import SwiftUI
import VaultCore

/// Adds or edits one staged secret or variable (nested in New Repository). The value is entered
/// only through ``SecretValueEditor``; the window is protected from screen capture while open.
struct CreateRepoItemSheet: View {
    @Bindable var editor: CreateRepoItemEditorViewModel
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(String(localized: "createRepo.item.scope", defaultValue: "In \(editor.scopeTitle)"))
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            Picker(String(localized: "createRepo.item.kind", defaultValue: "Kind"), selection: $editor.kind) {
                ForEach(ConfigKind.allCases, id: \.self) { kind in
                    Text(CreateRepoText.kindTitle(kind)).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                Text(String(localized: "createRepo.item.name", defaultValue: "Name"))
                    .font(Theme.Typography.callout.weight(.semibold))
                TextField(
                    String(localized: "createRepo.item.name", defaultValue: "Name"),
                    text: $editor.name,
                    prompt: Text(verbatim: "API_TOKEN")
                )
                .textFieldStyle(.roundedBorder)
                .font(Theme.Typography.monospaced)
                .autocorrectionDisabled()
                .labelsHidden()
                if let error = editor.nameError {
                    HStack(spacing: Theme.Spacing.small) {
                        CreateRepoNoteView(text: error, detail: nil, systemImage: "exclamationmark.circle", tint: Theme.Colors.danger)
                        if let suggestion = editor.suggestedName {
                            Spacer()
                            Button(
                                String(localized: "createRepo.name.useSuggestion", defaultValue: "Use \(suggestion)"),
                                action: editor.applySuggestedName
                            )
                            .buttonStyle(.link)
                        }
                    }
                }
                if let error = editor.capacityError {
                    CreateRepoNoteView(text: error, detail: nil, systemImage: "exclamationmark.circle", tint: Theme.Colors.danger)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                Text(String(localized: "createRepo.item.value", defaultValue: "Value"))
                    .font(Theme.Typography.callout.weight(.semibold))
                SecretValueEditor(value: $editor.value)
                if let error = editor.valueError {
                    CreateRepoNoteView(text: error, detail: nil, systemImage: "exclamationmark.circle", tint: Theme.Colors.danger)
                }
                if editor.looksLikeCredential {
                    HStack(spacing: Theme.Spacing.small) {
                        CreateRepoNoteView(
                            text: String(localized: "createRepo.item.credential", defaultValue: "This looks like a credential"),
                            detail: String(
                                localized: "createRepo.item.credential.detail",
                                defaultValue: "Variables are readable by anyone who can read the repository's settings and workflow logs."
                            ),
                            systemImage: "exclamationmark.shield",
                            tint: Theme.Colors.warning
                        )
                        Spacer()
                        Button(String(localized: "createRepo.item.makeSecret", defaultValue: "Make It a Secret"), action: editor.makeSecret)
                    }
                }
            }
            HStack {
                Button(String(localized: "common.cancel", defaultValue: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(saveTitle) {
                    editor.save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!editor.canSave)
            }
        }
        .padding(Theme.Spacing.xLarge)
        .frame(width: Theme.Layout.createRepoEditorWidth)
        .screenCaptureProtected()
    }

    private var title: String {
        switch (editor.isNew, editor.kind) {
        case (true, .secret): String(localized: "createRepo.item.newSecret", defaultValue: "New Secret")
        case (true, .variable): String(localized: "createRepo.item.newVariable", defaultValue: "New Variable")
        case (false, .secret): String(localized: "createRepo.item.editSecret", defaultValue: "Edit Secret")
        case (false, .variable): String(localized: "createRepo.item.editVariable", defaultValue: "Edit Variable")
        }
    }

    private var saveTitle: String {
        editor.isNew
            ? String(localized: "createRepo.item.add", defaultValue: "Add")
            : String(localized: "createRepo.item.save", defaultValue: "Save")
    }
}
