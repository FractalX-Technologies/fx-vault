import AppKit
import VaultCore

/// Items copied with ⌘C on the detail table (v0.4.0), by id: their values stay in the vault and
/// only their names go to the pasteboard. App-wide since v0.4.1, so they paste into any
/// repository of the vault.
struct CopiedItemsModel: Hashable {
    let ids: [ConfigItemID]
    let names: [String]
    /// The scope or folder (v0.7.0) they were copied from.
    let source: ItemPlaceModel
}

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
        /// The copying app's bundle identifier (nspasteboard.org): `.dev` in Debug builds.
        static var sourceIdentifier: String {
            AppIdentity.bundleIdentifier
        }
    }

    private let pasteboard: NSPasteboard
    private let clock: any VaultClock
    let clearDelay: Duration

    /// `changeCount` right after our last write, or nil when we own nothing.
    private var ownedChangeCount: Int?
    /// `changeCount` right after the last ``copyItemNames(_:)``.
    private var itemNamesChangeCount: Int?
    /// The items of the last ``copyItems(_:)``, until the vault locks.
    private var copiedItems: CopiedItemsModel?
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

    /// ⌘C on the detail table (v0.4.0): the copied items' names, one per line, with the
    /// Transient and source markers so clipboard managers skip them; never values. The items
    /// stay in the app, and a paste in FX Vault pastes them while ``holdsItemNames`` is true.
    func copyItemNames(_ names: [String]) {
        pendingClear?.cancel()
        pendingClear = nil
        ownedChangeCount = nil
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString(names.joined(separator: "\n"), forType: .string)
        item.setData(Data(), forType: Marker.transient)
        item.setString(Marker.sourceIdentifier, forType: Marker.source)
        guard pasteboard.writeObjects([item]) else {
            itemNamesChangeCount = nil
            AppLog.ui.error("Pasteboard write failed")
            return
        }
        itemNamesChangeCount = pasteboard.changeCount
    }

    /// True while the pasteboard still holds the last ``copyItemNames(_:)`` (judged by
    /// `changeCount` only: anything copied since, in any app, makes it false).
    var holdsItemNames: Bool {
        itemNamesChangeCount == pasteboard.changeCount
    }

    /// ⌘C on the detail table: keeps `items` for a paste in any repository (v0.4.1) and puts
    /// their names on the pasteboard (``copyItemNames(_:)``).
    func copyItems(_ items: CopiedItemsModel) {
        copyItemNames(items.names)
        copiedItems = items
    }

    /// The items to paste: the last ``copyItems(_:)`` while the pasteboard still holds their
    /// names; nil once anything else was copied or the vault locked.
    var itemsToPaste: CopiedItemsModel? {
        holdsItemNames ? copiedItems : nil
    }

    /// Forgets the copied items (lock, terminate). The names on the pasteboard are not secret.
    func forgetCopiedItems() {
        copiedItems = nil
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
