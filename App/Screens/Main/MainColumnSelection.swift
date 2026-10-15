import SwiftUI

/// Keyboard selection for the custom-drawn columns of the main window (sidebar repositories and
/// scopes). Those columns draw their own rows (`.fxRowBackground`, docs/DESIGN.md "Main window")
/// instead of a native `List` selection, so the Up and Down arrows are handled here.
enum MainColumnSelection {
    /// The id that Up or Down selects next, or nil when the selection stays (the first or last
    /// row, Left/Right, an empty column). With nothing selected, Down picks the first row and Up
    /// the last.
    static func id<ID: Equatable>(after current: ID?, in ids: [ID], direction: MoveCommandDirection) -> ID? {
        guard let first = ids.first, let last = ids.last else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            switch direction {
            case .down: return first
            case .up: return last
            default: return nil
            }
        }
        switch direction {
        case .up: return index > ids.startIndex ? ids[index - 1] : nil
        case .down: return index < ids.index(before: ids.endIndex) ? ids[index + 1] : nil
        default: return nil
        }
    }
}

private struct MainColumnKeyboardSelection<ID: Hashable>: ViewModifier {
    let ids: [ID]
    @Binding var selection: ID?
    let isFocused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .focusable()
                .focused(isFocused)
                .focusEffectDisabled()
                .onMoveCommand { direction in
                    guard let next = MainColumnSelection.id(after: selection, in: ids, direction: direction) else { return }
                    selection = next
                    withAnimation(Theme.Durations.interactionAnimation) {
                        proxy.scrollTo(next)
                    }
                }
        }
    }
}

extension View {
    /// Makes a column of selectable rows keyboard-navigable: the column takes focus (rows set
    /// `isFocused` when clicked), Up and Down move `selection` through `ids` in display order and
    /// scroll the row into view. Every row needs `.id(rowID)`.
    func mainColumnKeyboardSelection<ID: Hashable>(
        ids: [ID],
        selection: Binding<ID?>,
        isFocused: FocusState<Bool>.Binding
    ) -> some View {
        modifier(MainColumnKeyboardSelection(ids: ids, selection: selection, isFocused: isFocused))
    }
}
