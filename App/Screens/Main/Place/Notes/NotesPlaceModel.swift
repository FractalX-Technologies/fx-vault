import Foundation
import Observation
import SyncEngine
import VaultCore
import VaultData

/// What ``PlaceNotesView`` needs from the place that owns it (1.0 B9): a repository scope, a
/// folder, a Key Vault or an organization.
protocol NotesPlaceModel: AnyObject, Observable {
    var notes: NotesDocumentModel { get }
    var notesReveal: NotesRevealModel { get }
    /// The place as VoiceOver names its notes ("api-service › production").
    var notesPlaceName: String { get }
    /// What the ○ mark means here: "Changed on GitHub", "Changed in Key Vault".
    var changedAtSourceTitle: String { get }
}

extension NotesPlaceModel {
    var changedAtSourceTitle: String {
        PlaceCopy.changedOnGitHubMark
    }
}

extension NotesPlaceModel where Self: ConfigTableModel {
    /// One section per kind the place holds, pending deletions left out (they show in the
    /// table until Sync), then the organization items a repository gets (B7a), read only.
    var notes: NotesDocumentModel {
        let rows = notesKinds.flatMap { tableRows(of: $0) }.filter { !$0.isDeleted }
        var sections = notesKinds.map { kind in
            let lines = rows.filter { $0.kind == kind && $0.inherited == nil }.map(notesLine)
            return NotesSectionModel(title: CopyAllCopy.section(kind, count: lines.count), lines: lines)
        }
        let inherited = rows.filter { $0.inherited != nil }
        if let organization = inherited.first?.inherited?.organization {
            sections.append(NotesSectionModel(
                title: NotesCopy.inheritedSection(organization: organization, count: inherited.count),
                lines: inherited.map(notesLine)
            ))
        }
        return NotesDocumentModel(sections: sections)
    }

    private func notesLine(_ row: ConfigRowModel) -> NotesItemLineModel {
        let isOwn = row.inherited == nil
        return NotesItemLineModel(
            id: row.id,
            name: row.name,
            kind: row.kind,
            value: display(for: row),
            mark: isOwn && showsSyncStatus
                ? NotesMarkModel.mark(isChangedAtSource: changedAtSourceIDs.contains(row.id), status: row.status)
                : nil,
            note: row.notesNote,
            canReveal: isOwn && row.kind == .secret && row.hasValue,
            isInherited: !isOwn
        )
    }
}

extension ConfigRowModel {
    /// The line's trailing note: an inherited item's reach, or "no value" and "overrides
    /// example-org" (board Main2-Repository).
    var notesNote: String? {
        if let inherited {
            return inherited.reach
        }
        let note = PlaceCopy.subline([
            kind == .secret && !hasValue ? NotesCopy.noValue : nil,
            overrides.map(NotesCopy.overrides),
        ])
        return note.isEmpty ? nil : note
    }
}

extension DriftReportModel {
    /// The items of `scope` the last check found changed on GitHub (the notes' ○ marks). A
    /// name only GitHub has has no line to mark.
    func changedItemIDs(in scope: ConfigScope) -> Set<ConfigItemID> {
        Set(drifts.compactMap { drift in
            guard case .item(let item) = drift.subject, item.scope == scope else { return nil }
            return item.itemID
        })
    }
}
