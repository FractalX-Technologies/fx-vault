import Foundation
import Observation
import SwiftUI
import VaultCore

/// The ⌘K jump palette (1.0 D6c2, D6c5; board Main2-Search): the places the sidebar lists, taken
/// when it opens, filtered as you type (``JumpPlaces/filter(_:query:)``), then the secrets and
/// variables whose name holds the text ("Secrets by name", never a value). ↑↓ move the selection
/// across both sections, ↩ opens it through `open`, which also closes the palette.
@Observable
final class JumpPaletteViewModel {
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            results = JumpPlaces.filter(places, query: query)
            items = searchItems(query)
            selectedID = resultIDs.first
        }
    }
    private(set) var results: [JumpPlaceModel]
    /// "Secrets by name": empty until something is typed.
    private(set) var items: [JumpItemModel] = []
    var selectedID: JumpResultID?

    @ObservationIgnored private let places: [JumpPlaceModel]
    @ObservationIgnored private let searchItems: (String) -> [JumpItemModel]
    @ObservationIgnored private let onOpen: (JumpPlaceTarget) -> Void
    @ObservationIgnored private let onOpenItem: (JumpItemModel) -> Void

    /// - Parameter items: the names that match a query (``JumpPlaces/items(_:in:)``).
    init(
        places: [JumpPlaceModel],
        items: @escaping (String) -> [JumpItemModel] = { _ in [] },
        open: @escaping (JumpPlaceTarget) -> Void,
        openItem: @escaping (JumpItemModel) -> Void = { _ in }
    ) {
        self.places = places
        searchItems = items
        onOpen = open
        onOpenItem = openItem
        results = places
        selectedID = places.first.map { .place($0.id) }
    }

    /// The rows in screen order: the places, then the names.
    private var resultIDs: [JumpResultID] {
        results.map { .place($0.id) } + items.map { .item($0.id) }
    }

    /// Up and Down, stopping at the first and the last row.
    func moveSelection(_ direction: MoveCommandDirection) {
        guard let next = MainColumnSelection.id(after: selectedID, in: resultIDs, direction: direction) else { return }
        selectedID = next
    }

    /// ↩: opens the selected row; with nothing to open the palette stays.
    func open() {
        switch selectedID {
        case .place(let target):
            guard let place = results.first(where: { $0.id == target }) else { return }
            onOpen(place.target)
        case .item(let id):
            guard let item = items.first(where: { $0.id == id }) else { return }
            onOpenItem(item)
        case nil:
            return
        }
    }

    /// A click on a place.
    func open(_ place: JumpPlaceModel) {
        onOpen(place.target)
    }

    /// A click on a name.
    func open(_ item: JumpItemModel) {
        onOpenItem(item)
    }

    func highlight(in name: String) -> Range<String.Index>? {
        JumpPlaces.highlight(in: name, query: query)
    }
}
