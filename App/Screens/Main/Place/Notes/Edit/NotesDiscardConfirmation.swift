import SwiftUI

/// "Discard 3 unsaved changes?" before another place, scope or Table drops an edit of the notes.
struct NotesDiscardRequestModel: Equatable {
    let count: Int
}

extension View {
    /// Discard ends the edit, then goes where the user went; Keep Editing (or Esc) goes back.
    func notesDiscardConfirmation(_ main: MainViewModel) -> some View {
        confirmationDialog(
            NotesEditCopy.discardTitle(main.discardRequest?.count ?? 0),
            isPresented: Binding(get: { main.discardRequest != nil }, set: { isPresented in
                // SwiftUI may close the dialog before it runs Discard's action: Keep Editing
                // waits a turn, and does nothing once Discard has answered.
                guard !isPresented else { return }
                Task { @MainActor in
                    main.keepEditingNotes()
                }
            }),
            titleVisibility: .visible
        ) {
            Button(NotesEditCopy.discard, role: .destructive) {
                main.discardNotesEdit()
            }
            Button(NotesEditCopy.keepEditing, role: .cancel) {
                main.keepEditingNotes()
            }
        } message: {
            Text(NotesEditCopy.discardMessage)
        }
    }
}
