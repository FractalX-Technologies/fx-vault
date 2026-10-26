import SwiftUI

/// Asks for a field's focus until it lands. SwiftUI drops a request made while the field is
/// still being inserted (the ⌘K palette's overlay, the sidebar sliding back after Edit › Find),
/// so it is made again every `focusRetry`, up to `focusTimeout`.
enum FocusRetry {
    /// True once the field has the focus; false when `isWanted` turns false, the task is
    /// cancelled or the time runs out.
    @discardableResult
    static func take(
        isFocused: () -> Bool,
        isWanted: () -> Bool = { true },
        focus: () -> Void
    ) async -> Bool {
        let attempts = Int(Theme.Durations.focusTimeout / Theme.Durations.focusRetry)
        for _ in 0..<attempts {
            if isFocused() { return true }
            guard isWanted() else { return false }
            focus()
            do {
                try await Task.sleep(for: Theme.Durations.focusRetry)
            } catch {
                return isFocused()
            }
        }
        return isFocused()
    }
}
