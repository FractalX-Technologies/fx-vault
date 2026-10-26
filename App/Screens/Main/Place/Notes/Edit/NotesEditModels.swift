import Foundation
import VaultCore

/// A value the notes editor holds outside its text (1.0 N2): a secret's, or a variable's with line
/// breaks. The text holds one attachment character for it, so the value never enters the text,
/// its undo or the pasteboard ("masked values are placeholders, spliced back at save").
struct NotesTokenID: Hashable {
    let rawValue: UUID

    init() {
        rawValue = UUID()
    }
}

/// What the analysis knows of a token: never its value.
struct NotesTokenModel: Hashable {
    let id: NotesTokenID
    /// The kind it was made for (its section, or its item's).
    let kind: ConfigKind
    /// The item whose value it stands for; nil for a new line's.
    let origin: ConfigItemID?
    /// True when it has a value: one set while editing, or its item's.
    let hasValue: Bool
    /// The size of a value set while editing (after D32); nil when none was set.
    let newValueBytes: Int?
}

/// An item of the place as the edit started (its line's origin).
struct NotesEditOriginModel: Hashable, Identifiable {
    let id: ConfigItemID
    let name: String
    let kind: ConfigKind
    let isSynced: Bool
    let hasValue: Bool
    /// A variable's value (variables show in plaintext); nil for a secret.
    let variableValue: String?
    let mark: NotesMarkModel?
    /// The unchanged line's note: "no value", "overrides example-org".
    let note: String?
    /// The organization whose item of the same name this one overrides (the Review's removal).
    let overrides: String?
    /// The file a secret's value came from (1.0 F1), named on its token as in the notes.
    var file: FileSecretModel?

    /// A variable's value as its line's text: one line only, else it is held as a token.
    var text: String? {
        variableValue.flatMap { $0.contains(where: \.isNewline) ? nil : $0 }
    }
}

/// One paragraph of the editor's text, as the analysis reads it.
struct NotesParagraphModel: Hashable {
    /// The text, with U+FFFC where a token is.
    let text: String
    /// A section's protected `# Secrets` or `# Variables` line.
    var heading: ConfigKind?
    /// The tokens, in text order.
    var tokens: [NotesTokenID] = []
    /// The existing variable whose characters the line still holds (its identity).
    var itemID: ConfigItemID?
}

/// A line's trailing note: what changed, or why it can't be saved.
struct NotesEditNoteModel: Hashable {
    let text: String
    let isError: Bool

    static func info(_ text: String) -> Self {
        Self(text: text, isError: false)
    }

    static func error(_ text: String) -> Self {
        Self(text: text, isError: true)
    }
}

/// The analysis of one paragraph.
struct NotesEditLineModel: Hashable {
    enum Role: Hashable {
        case heading(ConfigKind)
        case blank
        case comment
        case item
    }

    let role: Role
    var mark: NotesMarkModel?
    var note: NotesEditNoteModel?
    /// The name's UTF-16 range in the paragraph, underlined while the name is the problem.
    var nameErrorRange: NSRange?
}

/// A value the save writes: text from the editor, or a token's.
enum NotesEditValueModel: Hashable {
    case text(String)
    case token(NotesTokenID)
}

/// What a save would do (the Review's Added, Changed and Removed).
struct NotesEditPlanModel: Hashable {
    struct Addition: Hashable {
        let kind: ConfigKind
        let name: String
        let value: NotesEditValueModel
    }

    struct Change: Hashable {
        let origin: NotesEditOriginModel
        /// The new name; nil keeps it.
        let name: String?
        /// The new value; nil keeps it.
        let value: NotesEditValueModel?
    }

    var additions: [Addition] = []
    var changes: [Change] = []
    var removals: [NotesEditOriginModel] = []

    var count: Int {
        additions.count + changes.count + removals.count
    }
}

/// The editor's text read as notes: a line model per paragraph and the save it would make.
struct NotesEditAnalysisModel: Hashable {
    var lines: [NotesEditLineModel] = []
    var plan = NotesEditPlanModel()

    var errorCount: Int {
        lines.lazy.filter { $0.note?.isError == true }.count
    }
}

/// Where the editor drew its lines: the gutter, the notes and the underlines follow it.
struct NotesEditLayoutModel: Equatable {
    var height: CGFloat = 0
    /// The text view's width: the line notes take its part past the text's.
    var width: CGFloat = 0
    /// Each paragraph's frame, in the text view.
    var lines: [CGRect] = []
    /// Under the names lines can't save (board Place-Errors): each name's width on its line.
    var squiggles: [CGRect] = []
    /// Where each heading's text ends, by paragraph: its count follows.
    var headingEnds: [Int: CGFloat] = [:]
    /// The paragraph with the insertion point.
    var caretLine: Int?
}
