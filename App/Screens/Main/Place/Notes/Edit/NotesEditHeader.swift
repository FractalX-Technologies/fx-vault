import SwiftUI

/// A place's header while its notes are edited (boards Place-Edit, Place-Errors): the name,
/// "Editing · …", then "4 unsaved changes" or "Fix 4 lines to save", Cancel and Review ⌘S.
struct NotesEditHeader: View {
    let title: String
    var titleStyle: SidebarTitleStyle = .mono
    let session: NotesEditSession

    var body: some View {
        PlaceHeader(title: title, titleStyle: titleStyle, subline: session.subline, showsMore: false) {
            NotesEditActions(session: session)
        } moreItems: {
            EmptyView()
        }
    }
}

private struct NotesEditActions: View {
    let session: NotesEditSession

    var body: some View {
        if session.errorCount > 0 {
            Text(NotesEditCopy.fixLines(session.errorCount))
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.danger)
        } else if session.changeCount > 0 {
            Text(NotesEditCopy.unsavedChanges(session.changeCount))
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.subtleText)
        }
        // No Esc: one key would drop every edit.
        Button(NotesEditCopy.cancel) {
            session.cancel()
        }
        .fxButtonStyle(.outline, size: .compact)
        .accessibilityIdentifier(AccessibilityID.Place.notesEditCancel)
        Button {
            session.requestReview()
        } label: {
            HStack(spacing: Theme.Spacing.smallMinus) {
                Text(NotesEditCopy.review)
                Text(verbatim: "⌘S")
                    .font(Theme.Typography.monoLabel)
                    .padding(.horizontal, Theme.Spacing.xSmall)
                    .frame(minHeight: Theme.Layout.badgeHeight)
                    .background(Theme.Colors.inkBadge, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    .accessibilityHidden(true)
            }
        }
        .fxButtonStyle(.primary, size: .compact)
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!session.canReview)
        .help(NotesEditCopy.reviewHelp)
        .accessibilityIdentifier(AccessibilityID.Place.notesReview)
    }
}

/// ⋯ More › Edit Notes (1.0 N2): the notes, then the editor at the end of the text.
struct NotesEditMenuItem<Model: NotesEditablePlaceModel>: View {
    let model: Model
    let main: MainViewModel

    var body: some View {
        Button(NotesEditCopy.edit) {
            main.placeViewMode = .notes
            model.beginNotesEdit(at: nil)
        }
        .disabled(!model.canEditNotes)
    }
}

/// A place's notes: read only, or the editor while an edit runs. Leaving the editor any way
/// (another place, Table, lock) drops the edit and wipes its values.
struct PlaceNotesContent<Model: NotesEditablePlaceModel>: View {
    let model: Model

    var body: some View {
        if let edit = model.notesEdit {
            NotesEditorView(session: edit, reveal: model.notesReveal, changedTitle: model.changedAtSourceTitle)
                .onDisappear {
                    edit.finish()
                }
        } else {
            PlaceNotesView(model: model, onEdit: model.canEditNotes ? { model.beginNotesEdit(at: $0) } : nil)
        }
    }
}
