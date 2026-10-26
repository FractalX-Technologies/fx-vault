import AppKit

/// The clipboard after a value was pasted from it (1.0 N2; board Place-Paste).
enum NotesClipboard {
    /// Clears what a paste read, unless something was copied since (`changeCount` moved): that
    /// copy is the user's. Returns whether it was cleared.
    @discardableResult
    static func clear(_ pasteboard: NSPasteboard, ifStillAt changeCount: Int) -> Bool {
        guard pasteboard.changeCount == changeCount else { return false }
        pasteboard.clearContents()
        return true
    }
}
