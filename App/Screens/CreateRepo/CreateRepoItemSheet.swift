import SwiftUI
import VaultCore

/// Adds or edits one staged secret or variable (nested in New Repository). The value is entered
/// only through ``SecretValueEditor``; the window is protected from screen capture while open.
struct CreateRepoItemSheet: View {
    @Bindable var editor: CreateRepoItemEditorViewModel
    let onCancel: () -> Void
    @FocusState private var isNameFocused: Bool

    var body: some View {
        ConfigEditorSheet(
            eyebrow: CreateRepoText.eyebrow,
            title: title,
            subtitle: String(localized: "createRepo.item.scope", defaultValue: "In \(editor.scopeTitle)"),
            primaryTitle: saveTitle,
            isPrimaryEnabled: editor.canSave,
            isWorking: false,
            width: Theme.Layout.createRepoEditorWidth,
            onCancel: onCancel,
            onPrimary: { editor.save() }
        ) {
            ConfigSheetField(String(localized: "createRepo.item.kind", defaultValue: "Kind")) {
                SegmentedPill(
                    selection: $editor.kind,
                    segments: ConfigKind.allCases.map { .init(value: $0, title: CreateRepoText.kindTitle($0)) },
                    accessibilityLabel: String(localized: "createRepo.item.kind", defaultValue: "Kind")
                )
            }
            ConfigSheetField(String(localized: "createRepo.item.name", defaultValue: "Name")) {
                TextField(
                    String(localized: "createRepo.item.name", defaultValue: "Name"),
                    text: $editor.name,
                    prompt: Text(verbatim: "API_TOKEN").foregroundStyle(Theme.Colors.subtleText)
                )
                .focused($isNameFocused)
                .autocorrectionDisabled()
                .labelsHidden()
                .fxInputField(
                    .rounded,
                    isFocused: isNameFocused,
                    isInvalid: editor.nameError != nil || editor.capacityError != nil,
                    isMonospaced: true
                )
                if let error = editor.nameError {
                    HStack(spacing: Theme.Spacing.small) {
                        CreateRepoNoteView(text: error, detail: nil, systemImage: "exclamationmark.circle", tint: Theme.Colors.danger)
                        if let suggestion = editor.suggestedName {
                            Spacer()
                            Button(
                                String(localized: "createRepo.name.useSuggestion", defaultValue: "Use \(suggestion)"),
                                action: editor.applySuggestedName
                            )
                            .fxButtonStyle(.outline)
                        }
                    }
                }
                if let error = editor.capacityError {
                    CreateRepoNoteView(text: error, detail: nil, systemImage: "exclamationmark.circle", tint: Theme.Colors.danger)
                }
            }
            ConfigSheetField(String(localized: "createRepo.item.value", defaultValue: "Value")) {
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
                            .fxButtonStyle(.outline)
                    }
                    .configSheetRowPadding()
                    .background(Theme.Colors.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                }
            }
        }
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
