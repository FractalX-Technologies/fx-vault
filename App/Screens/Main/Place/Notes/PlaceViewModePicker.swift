import SwiftUI

/// Notes | Table on a place's header, after Copy All (1.0 B9; boards Main2-Repository,
/// Place-Table). One choice for every place while FX Vault runs (``MainViewModel/placeViewMode``).
struct PlaceViewModePicker: View {
    let main: MainViewModel

    var body: some View {
        // Through `show`: Table asks before it drops an edit of the notes (1.0 N2).
        let mode = Binding(get: { main.placeViewMode }, set: { main.show($0) })
        SegmentedPill(
            selection: mode,
            segments: [
                .init(value: PlaceViewMode.notes, title: NotesCopy.notes),
                .init(value: PlaceViewMode.table, title: NotesCopy.table),
            ],
            accessibilityLabel: NotesCopy.viewMode,
            size: .small
        )
        .fixedSize()
        .accessibilityIdentifier(AccessibilityID.Place.viewMode)
    }
}
