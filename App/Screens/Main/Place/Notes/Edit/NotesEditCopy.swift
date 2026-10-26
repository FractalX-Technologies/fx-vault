import Foundation
import VaultCore

/// The texts of the notes editor (1.0 N2; boards Place-Edit, Place-SecretValue, Place-Paste,
/// Place-Errors, KV-NameRules, Place-Review).
nonisolated enum NotesEditCopy {
    // MARK: - Header

    static let editingSubline = String(
        localized: "notesEdit.subline",
        defaultValue: "Editing · secret values stay masked; click one to set it"
    )

    /// "Editing · 4 lines can't be saved" (board Place-Errors).
    static func errorsSubline(_ count: Int) -> String {
        String(inflected: AttributedString(
            localized: "notesEdit.subline.errors",
            defaultValue: "Editing · ^[\(count) line](inflect: true) can't be saved"
        ))
    }

    static func unsavedChanges(_ count: Int) -> String {
        String(inflected: AttributedString(
            localized: "notesEdit.unsaved",
            defaultValue: "^[\(count) unsaved change](inflect: true)"
        ))
    }

    static func fixLines(_ count: Int) -> String {
        String(inflected: AttributedString(
            localized: "notesEdit.fixLines",
            defaultValue: "Fix ^[\(count) line](inflect: true) to save"
        ))
    }

    static let edit = String(localized: "notesEdit.edit", defaultValue: "Edit Notes")
    static let cancel = String(localized: "common.cancel", defaultValue: "Cancel")
    static let review = String(localized: "notesEdit.review", defaultValue: "Review")
    static let reviewHelp = String(localized: "notesEdit.review.help", defaultValue: "Review the changes before saving them (⌘S)")
    static let accessibilityLabel = String(localized: "notesEdit.accessibility", defaultValue: "Notes editor")
    static let cut = String(localized: "notesEdit.menu.cut", defaultValue: "Cut")
    static let copy = String(localized: "notesEdit.menu.copy", defaultValue: "Copy")
    static let selectAll = String(localized: "notesEdit.menu.selectAll", defaultValue: "Select All")

    /// A section's title in the editor: `# Secrets`, `# Variables`.
    static func sectionTitle(_ kind: ConfigKind) -> String {
        switch kind {
        case .secret: String(localized: "notesEdit.section.secrets", defaultValue: "Secrets")
        case .variable: String(localized: "notesEdit.section.variables", defaultValue: "Variables")
        }
    }

    /// The count after a section's title (board Place-Edit: "# Secrets · 6").
    static func sectionCount(_ count: Int) -> String {
        " · \(count)"
    }

    // MARK: - Line notes

    static func new(_ kind: ConfigKind) -> String {
        switch kind {
        case .secret: String(localized: "notesEdit.note.newSecret", defaultValue: "new · secret")
        case .variable: String(localized: "notesEdit.note.newVariable", defaultValue: "new · variable")
        }
    }

    /// A variable's value before the edit (board Place-Edit: "was info").
    static func was(_ value: String) -> String {
        String(localized: "notesEdit.note.was", defaultValue: "was \(value)")
    }

    static func renamed(from name: String) -> String {
        String(localized: "notesEdit.note.renamed", defaultValue: "renamed from \(name)")
    }

    static let replacesValue = String(localized: "notesEdit.note.replacesValue", defaultValue: "replaces value")
    static let valueSet = String(localized: "notesEdit.note.valueSet", defaultValue: "value set")

    /// The name FX Vault saves when it differs from the typed one (board KV-NameRules).
    static func savedAs(_ name: String) -> String {
        String(localized: "notesEdit.note.savedAs", defaultValue: "saved as \(name)")
    }

    static let commentNotSaved = String(localized: "notesEdit.note.comment", defaultValue: "comments aren't saved")

    // MARK: - Line errors (board Place-Errors)

    static let addName = String(localized: "notesEdit.error.addName", defaultValue: "Add a name")
    static let addEquals = String(localized: "notesEdit.error.addEquals", defaultValue: "Add = and a value")
    static let addValue = String(localized: "notesEdit.error.addValue", defaultValue: "Add a value")
    static let setValue = String(localized: "notesEdit.error.setValue", defaultValue: "Set a value")
    static let secretValueInText = String(
        localized: "notesEdit.error.secretInText",
        defaultValue: "Secret values are set with Set value…"
    )
    static let oneValue = String(localized: "notesEdit.error.oneValue", defaultValue: "One value per line")
    static let lettersDigits = String(localized: "notesEdit.error.characters", defaultValue: "Use letters, digits and _")
    static let leadingDigit = String(localized: "notesEdit.error.leadingDigit", defaultValue: "Names can't start with a digit")
    static let reservedPrefix = String(
        localized: "notesEdit.error.reservedPrefix",
        defaultValue: "Names can't start with \(GitHubNameValidator.reservedPrefix)"
    )
    static let reservedName = String(localized: "notesEdit.error.reservedName", defaultValue: "FX Vault reserves this name")

    static func tooLong(_ maxLength: Int) -> String {
        String(localized: "notesEdit.error.tooLong", defaultValue: "Names are at most \(maxLength) characters")
    }

    static func keyVaultTooLong(_ maxLength: Int) -> String {
        String(localized: "notesEdit.error.keyVaultTooLong", defaultValue: "Key Vault names are at most \(maxLength) characters")
    }

    /// "65,536 bytes · over GitHub's 48,000".
    static func tooLarge(bytes: Int, limit: Int, isKeyVault: Bool) -> String {
        let size = bytes.formatted()
        let max = limit.formatted()
        return isKeyVault
            ? String(localized: "notesEdit.error.tooLarge.keyVault", defaultValue: "\(size) bytes · over Key Vault's \(max)")
            : String(localized: "notesEdit.error.tooLarge.gitHub", defaultValue: "\(size) bytes · over GitHub's \(max)")
    }

    static func sameNameAsLine(_ line: Int) -> String {
        String(localized: "notesEdit.error.sameName", defaultValue: "Same name as line \(line)")
    }

    /// A new line whose Key Vault name an existing secret already has (board KV-NameRules).
    static func sameInKeyVault(_ remoteName: String) -> String {
        String(localized: "notesEdit.error.sameInKeyVault", defaultValue: "Same as \(remoteName) in Key Vault")
    }

    static func bothBecome(_ remoteName: String) -> String {
        String(localized: "notesEdit.error.bothBecome", defaultValue: "Both become \(remoteName) in Key Vault")
    }

    static let kindFixed = String(localized: "notesEdit.error.kindFixed", defaultValue: "Kind is fixed after Sync")
    /// A line in the other section than the one its item or token was made in: "Belongs under # Secrets".
    static func belongs(in kind: ConfigKind) -> String {
        let section = NotesCopy.heading(sectionTitle(kind))
        return String(localized: "notesEdit.error.belongsIn", defaultValue: "Belongs under \(section)")
    }

    // MARK: - Tokens

    static let setValueToken = String(localized: "notesEdit.token.setValue", defaultValue: "Set value…")

    /// A variable value with line breaks, kept as one token: "3 lines".
    static func lines(_ count: Int) -> String {
        String(inflected: AttributedString(localized: "notesEdit.token.lines", defaultValue: "^[\(count) line](inflect: true)"))
    }

    static func bytes(_ count: Int) -> String {
        String(localized: "notesEdit.token.bytes", defaultValue: "\(count.formatted()) bytes")
    }

    // MARK: - Set value… (board Place-SecretValue)

    static func valueTitle(_ name: String) -> String {
        String(localized: "notesEdit.value.title", defaultValue: "\(name) · value")
    }

    static let newValueTitle = String(localized: "notesEdit.value.titleUnnamed", defaultValue: "Value")
    static let paste = String(localized: "notesEdit.value.paste", defaultValue: "Paste")
    static let generate = String(localized: "notesEdit.value.generate", defaultValue: "Generate")
    static let generateHelp = String(
        localized: "notesEdit.value.generate.help",
        defaultValue: "A random value of 32 bytes, as 43 letters, digits, - and _"
    )
    static let kind = String(localized: "notesEdit.value.kind", defaultValue: "Kind")

    static func kindTitle(_ kind: ConfigKind) -> String {
        switch kind {
        case .secret: String(localized: "notesEdit.value.kind.secret", defaultValue: "Secret")
        case .variable: String(localized: "notesEdit.value.kind.variable", defaultValue: "Variable")
        }
    }

    static let kindFixedAfterSync = String(localized: "notesEdit.value.kindFixed", defaultValue: "The kind is fixed after its first Sync.")
    static let keepsCurrentValue = String(
        localized: "notesEdit.value.keepsCurrent",
        defaultValue: "Leave it empty to keep the current value."
    )
    static let done = String(localized: "notesEdit.value.done", defaultValue: "Done")

    // MARK: - Paste (board Place-Paste)

    /// The toast after `KEY=value` lines were pasted.
    static func pastedValues(_ count: Int) -> String {
        String(inflected: AttributedString(
            localized: "notesEdit.paste.values",
            defaultValue: "^[\(count) value](inflect: true) set from the clipboard · clipboard cleared"
        ))
    }

    /// Something was copied since the paste read the clipboard: it stays.
    static func pastedValuesKept(_ count: Int) -> String {
        String(inflected: AttributedString(
            localized: "notesEdit.paste.valuesKept",
            defaultValue: "^[\(count) value](inflect: true) set from the clipboard"
        ))
    }

    // MARK: - Leaving an edit

    /// Another place, scope or Table while the edit has changes.
    static func discardTitle(_ count: Int) -> String {
        String(inflected: AttributedString(
            localized: "notesEdit.discard.title",
            defaultValue: "Discard ^[\(count) unsaved change](inflect: true)?"
        ))
    }

    static let discardMessage = String(
        localized: "notesEdit.discard.message",
        defaultValue: "Your edits to the notes and the values you set are dropped. Nothing was saved."
    )
    static let discard = String(localized: "notesEdit.discard.confirm", defaultValue: "Discard")
    static let keepEditing = String(localized: "notesEdit.discard.keep", defaultValue: "Keep Editing")

    // MARK: - Review (board Place-Review)

    static func reviewTitle(_ place: String) -> String {
        String(localized: "notesEdit.review.title", defaultValue: "Review changes to \(place)")
    }

    static func changeCount(_ count: Int) -> String {
        String(inflected: AttributedString(localized: "notesEdit.review.count", defaultValue: "^[\(count) change](inflect: true)"))
    }

    static func added(_ count: Int) -> String {
        String(localized: "notesEdit.review.added", defaultValue: "Added · \(count)")
    }

    static func changed(_ count: Int) -> String {
        String(localized: "notesEdit.review.changed", defaultValue: "Changed · \(count)")
    }

    static func removed(_ count: Int) -> String {
        String(localized: "notesEdit.review.removed", defaultValue: "Removed · \(count)")
    }

    static func kindWord(_ kind: ConfigKind) -> String {
        switch kind {
        case .secret: String(localized: "notesEdit.kind.secret", defaultValue: "secret")
        case .variable: String(localized: "notesEdit.kind.variable", defaultValue: "variable")
        }
    }

    /// `text` cut to `maxLength` characters with an ellipsis (a variable's value in a note).
    static func shortened(_ text: String, maxLength: Int) -> String {
        text.count > maxLength ? String(text.prefix(maxLength - 1)) + "…" : text
    }

    /// A variable's value change: "info → debug".
    static func valueChange(from old: String, to new: String) -> String {
        "\(old) → \(new)"
    }

    /// A removed repository secret that overrides an organization one (board Place-Review).
    static func organizationValueApplies(_ organization: String) -> String {
        String(localized: "notesEdit.review.orgApplies", defaultValue: "\(organization)'s value applies after Sync")
    }

    static let footerGitHub = String(
        localized: "notesEdit.review.footer.gitHub",
        defaultValue: "Saved changes stay pending until Sync. Removed items are deleted from GitHub at Sync."
    )
    static let footerKeyVault = String(
        localized: "notesEdit.review.footer.keyVault",
        defaultValue: "Saved changes stay pending until Sync. Removed secrets are deleted in Key Vault at Sync."
    )
    static let footerFolder = String(
        localized: "notesEdit.review.footer.folder",
        defaultValue: "A folder saves at once and never sends anything by itself."
    )
    static let save = String(localized: "notesEdit.review.save", defaultValue: "Save")

    static let removedSection = String(localized: "notesEdit.removed.section", defaultValue: "Removed")
    static let removedNote = String(localized: "notesEdit.removed.note", defaultValue: "removed")
    static let undo = String(localized: "notesEdit.removed.undo", defaultValue: "Undo")

    static func restore(_ name: String) -> String {
        String(localized: "notesEdit.removed.restore", defaultValue: "Put \(name) back")
    }
}
