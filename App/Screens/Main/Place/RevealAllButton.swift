import SwiftUI

/// Reveal All on a place's header (board Place-Reveal): one Touch ID or master password shows
/// every secret of the notes for `Timeouts.revealAllRemask`, and a click on a line copies its
/// value meanwhile; Hide All while they show. From the table it opens the notes first.
struct RevealAllButton<Model: NotesPlaceModel>: View {
    let model: Model
    let main: MainViewModel

    var body: some View {
        let reveal = model.notesReveal
        let isRevealingAll = reveal.isRevealingAll
        Button {
            if !isRevealingAll {
                main.show(.notes)
            }
            reveal.toggleRevealAll(model.notes, place: model.notesPlaceName)
        } label: {
            Label(isRevealingAll ? NotesCopy.hideAll : NotesCopy.revealAll, systemImage: isRevealingAll ? "eye.slash" : "eye")
        }
        .fxButtonStyle(.outline, size: .compact)
        .disabled(!reveal.canToggleRevealAll(model.notes))
        .help(isRevealingAll ? "" : NotesCopy.revealAllHelp)
        .accessibilityIdentifier(AccessibilityID.Place.revealAll)
    }
}
