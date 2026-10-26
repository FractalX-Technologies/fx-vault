import Foundation
import VaultCore

/// What a place shows (1.0 B9; boards Main2-Repository, Place-Table): its notes, the default,
/// or the table with kinds, visibility and per-row actions.
enum PlaceViewMode: Hashable, CaseIterable {
    case notes
    case table
}

/// The gutter mark of a notes line (boards Main2-Repository, Place-Edit).
enum NotesMarkModel: Hashable {
    /// ○ The last check found it changed on GitHub or in Key Vault.
    case changedAtSource
    /// ● A change in this vault waits for the next Sync.
    case pending

    /// A change at the source wins: it needs a review, a pending change only a Sync.
    static func mark(isChangedAtSource: Bool, status: ConfigSyncStatus) -> Self? {
        if isChangedAtSource {
            return .changedAtSource
        }
        return status == .synced || status == .unverifiedShare ? nil : .pending
    }
}

/// One `KEY = value` line of a place's notes.
struct NotesItemLineModel: Hashable {
    let id: ConfigItemID
    let name: String
    let kind: ConfigKind
    /// Masked until revealed (a secret), plaintext (a variable) or missing.
    let value: ConfigValueDisplayModel
    var mark: NotesMarkModel?
    /// The trailing edge: "no value", "overrides example-org", an organization item's reach.
    var note: String?
    /// A secret of this place with a value here; an inherited one is read only.
    var canReveal: Bool
    /// An organization item a repository gets (B7a): drawn muted, never revealed.
    var isInherited = false
}

/// A section: its `# Secrets · 6` title and its lines.
struct NotesSectionModel: Hashable {
    let title: String
    let lines: [NotesItemLineModel]
}

/// A line's identity: headings and blank lines by section, items by id.
enum NotesLineID: Hashable {
    case heading(Int)
    case blank(Int)
    case item(ConfigItemID)
}

struct NotesLineModel: Identifiable, Hashable {
    enum Content: Hashable {
        /// A section's title, without its `# `.
        case heading(String)
        case blank
        case item(NotesItemLineModel)
    }

    let id: NotesLineID
    /// From 1, as the gutter numbers it.
    let number: Int
    let content: Content
}

/// A place's notes (1.0 B9; boards Main2-Repository, KV-Place): each section's heading and
/// lines, a blank line between sections, numbered from 1.
struct NotesDocumentModel: Hashable {
    let lines: [NotesLineModel]

    init(sections: [NotesSectionModel]) {
        var lines: [NotesLineModel] = []
        for (index, section) in sections.enumerated() {
            if index > 0 {
                lines.append(NotesLineModel(id: .blank(index), number: lines.count + 1, content: .blank))
            }
            lines.append(NotesLineModel(id: .heading(index), number: lines.count + 1, content: .heading(section.title)))
            for line in section.lines {
                lines.append(NotesLineModel(id: .item(line.id), number: lines.count + 1, content: .item(line)))
            }
        }
        self.lines = lines
    }

    /// The `KEY = value` lines, in order.
    var items: [NotesItemLineModel] {
        lines.compactMap { line in
            if case .item(let item) = line.content { item } else { nil }
        }
    }
}
