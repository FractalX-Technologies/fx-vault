import Foundation
import VaultCore

/// A place whose notes can be edited (1.0 N2): a repository scope, a folder or a Key Vault. An
/// organization's notes stay read only in 1.0, so it is a ``NotesPlaceModel`` only.
protocol NotesEditablePlaceModel: NotesPlaceModel {
    /// The edit in progress; nil while the notes are read only.
    var notesEdit: NotesEditSession? { get set }
    var canEditNotes: Bool { get }
    /// Starts an edit with the caret at the end of line `line` (from 1), or of the text.
    func beginNotesEdit(at line: Int?)
}

extension NotesEditablePlaceModel {
    /// Starts an edit from `origins`: revealed values are hidden first (anton D3), and the place
    /// reads only again once it is saved or cancelled.
    func startNotesEdit(
        target: NotesEditTargetModel,
        origins: [NotesEditOriginModel],
        inherited: NotesSectionModel?,
        caretLine: Int?
    ) {
        guard canEditNotes, notesEdit == nil else { return }
        notesReveal.cancel()
        notesReveal.hideAll()
        let session = NotesEditSession(target: target, origins: origins, inherited: inherited)
        session.caretLine = caretLine
        session.onFinish = { [weak self] in
            self?.notesEdit = nil
        }
        session.onSaved = { [weak self] names in
            self?.notesReveal.showSaved(names)
        }
        notesEdit = session
    }
}

extension NotesEditablePlaceModel where Self: ConfigTableModel {
    var canEditNotes: Bool {
        canEdit
    }

    // A drop, a paste or an import writes to the vault at once, around the edit's pending text.
    var acceptsOutsideEdits: Bool {
        canEdit && notesEdit == nil
    }

    /// The place's own lines as an edit starts from them (pending deletions are gone already),
    /// with what only their rows know: synced, a value, the organization item it overrides.
    var notesEditOrigins: [NotesEditOriginModel] {
        let rows = Dictionary(notesKinds.flatMap { tableRows(of: $0) }.map { ($0.id, $0) }) { first, _ in first }
        return notes.items.compactMap { line in
            guard !line.isInherited, let row = rows[line.id] else { return nil }
            var variableValue: String?
            if case .plain(let value) = line.value {
                variableValue = value
            }
            return NotesEditOriginModel(
                id: line.id,
                name: line.name,
                kind: line.kind,
                isSynced: row.isSynced,
                hasValue: row.hasValue,
                variableValue: variableValue,
                mark: line.mark,
                note: line.note,
                overrides: row.overrides,
                file: line.file
            )
        }
    }

    /// The organization items a repository gets (B7a), read only under the editor as in the
    /// notes: the section after the last heading, whose lines are all inherited.
    var notesInheritedSection: NotesSectionModel? {
        let lines = notes.lines
        guard let first = lines.firstIndex(where: \.isInherited), first > lines.startIndex,
              case .heading(let title) = lines[first - 1].content
        else { return nil }
        let items = lines[first...].compactMap { line -> NotesItemLineModel? in
            if case .item(let item) = line.content, item.isInherited { item } else { nil }
        }
        return NotesSectionModel(title: title, lines: items)
    }

    /// Starts an edit of the place's own items, the organization's under them.
    func startNotesEdit(target: NotesEditTargetModel, caretLine: Int?) {
        startNotesEdit(target: target, origins: notesEditOrigins, inherited: notesInheritedSection, caretLine: caretLine)
    }
}

extension NotesLineModel {
    /// An organization item a repository gets: never edited there.
    var isInherited: Bool {
        if case .item(let item) = content { item.isInherited } else { false }
    }
}
