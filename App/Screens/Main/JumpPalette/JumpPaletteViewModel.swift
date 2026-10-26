import Foundation
import Observation
import SwiftUI

/// The ⌘K jump palette (1.0 D6c2; board Main2-Search): the places the sidebar lists, taken when
/// it opens, filtered as you type (``JumpPlaces/filter(_:query:)``). ↑↓ move the selection,
/// ↩ opens it through `open`, which also closes the palette (``MainViewModel/jump(to:)``).
@Observable
final class JumpPaletteViewModel {
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            results = JumpPlaces.filter(places, query: query)
            selectedID = results.first?.id
        }
    }
    private(set) var results: [JumpPlaceModel]
    var selectedID: JumpPlaceModel.ID?

    @ObservationIgnored private let places: [JumpPlaceModel]
    @ObservationIgnored private let onOpen: (JumpPlaceTarget) -> Void

    init(places: [JumpPlaceModel], open: @escaping (JumpPlaceTarget) -> Void) {
        self.places = places
        onOpen = open
        results = places
        selectedID = places.first?.id
    }

    /// Up and Down, stopping at the first and the last place.
    func moveSelection(_ direction: MoveCommandDirection) {
        guard let next = MainColumnSelection.id(after: selectedID, in: results.map(\.id), direction: direction) else { return }
        selectedID = next
    }

    /// ↩: opens the selected place; with nothing to open the palette stays.
    func open() {
        guard let place = results.first(where: { $0.id == selectedID }) else { return }
        onOpen(place.target)
    }

    /// A click on a row.
    func open(_ place: JumpPlaceModel) {
        onOpen(place.target)
    }

    func highlight(in name: String) -> Range<String.Index>? {
        JumpPlaces.highlight(in: name, query: query)
    }
}
