import AppKit
import VaultCore

/// Copies values to the pasteboard and clears them again (§5.9, D17).
///
/// - Every copy is `.currentHostOnly` (no Universal Clipboard) and carries the
///   `org.nspasteboard` Concealed, Transient and source markers, so clipboard managers skip it.
/// - The pasteboard is **never read**: reading it triggers the macOS privacy alert. Ownership is
///   tracked by `changeCount` alone.
/// - ``clearDelay`` after a copy (30 s), and on lock and terminate (``clearIfOwned()``), the
///   pasteboard is cleared only if nothing else has written to it since.
final class ClipboardManager {
    enum Marker {
        static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        static let source = NSPasteboard.PasteboardType("org.nspasteboard.source")
        static let sourceIdentifier = "io.fractalx.fxvault"
    }

    private let pasteboard: NSPasteboard
    private let clock: any VaultClock
    let clearDelay: Duration

    /// `changeCount` right after our last write, or nil when we own nothing.
    private var ownedChangeCount: Int?
    /// The scheduled clear for the last copy. Internal so tests can await it.
    private(set) var pendingClear: Task<Void, Never>?

    init(pasteboard: NSPasteboard, clock: any VaultClock, clearDelay: Duration = Timeouts.clipboardClear) {
        self.pasteboard = pasteboard
        self.clock = clock
        self.clearDelay = clearDelay
    }

    /// True while the pasteboard still holds our last copy (judged by `changeCount` only).
    var ownsContents: Bool {
        guard let ownedChangeCount else { return false }
        return pasteboard.changeCount == ownedChangeCount
    }

    /// Writes `value` with the privacy markers and schedules the clear.
    func copy(_ value: String) {
        pendingClear?.cancel()
        pendingClear = nil
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        item.setData(Data(), forType: Marker.concealed)
        item.setData(Data(), forType: Marker.transient)
        item.setString(Marker.sourceIdentifier, forType: Marker.source)
        guard pasteboard.writeObjects([item]) else {
            ownedChangeCount = nil
            AppLog.ui.error("Pasteboard write failed")
            return
        }
        ownedChangeCount = pasteboard.changeCount
        let clock = clock
        let delay = clearDelay
        pendingClear = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            self?.clearIfOwned()
        }
    }

    /// Copies a non-secret text such as a command (`brew install gh`, a scope fix command): a
    /// plain string, not concealed, never cleared. A value FX Vault still owns is replaced, so
    /// it is no longer tracked.
    func copyCommand(_ text: String) {
        pendingClear?.cancel()
        pendingClear = nil
        ownedChangeCount = nil
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.setString(text, forType: .string) else {
            AppLog.ui.error("Pasteboard write failed")
            return
        }
    }

    /// Clears the pasteboard if it still holds our last copy (lock, terminate, timer).
    func clearIfOwned() {
        pendingClear?.cancel()
        pendingClear = nil
        guard let owned = ownedChangeCount else { return }
        ownedChangeCount = nil
        if pasteboard.changeCount == owned {
            pasteboard.clearContents()
        }
    }
}
