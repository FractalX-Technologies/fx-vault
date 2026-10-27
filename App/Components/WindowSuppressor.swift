import AppKit

/// Keeps a window off screen while `isSuppressed` holds: `suppress` runs each time it reaches the
/// screen, and it stays transparent meanwhile so no frame flashes. SwiftUI orders the main window
/// front after handing it to ``WindowAccessor``, and again about half a second later in its
/// launch, so closing it once was not enough: 1.0.0 and 1.0.1 opened locked with the lock window
/// beside the island.
@MainActor
final class WindowSuppressor {
    private weak var window: NSWindow?
    private var observer: NSObjectProtocol?
    private let isSuppressed: () -> Bool
    private let suppress: (NSWindow) -> Void

    init(isSuppressed: @escaping () -> Bool, suppress: @escaping (NSWindow) -> Void) {
        self.isSuppressed = isSuppressed
        self.suppress = suppress
    }

    /// Watches `window` from now on, deciding at once when it is already visible. AppKit updates
    /// every visible window once per event loop pass, the moment to decide.
    func watch(_ window: NSWindow) {
        guard window !== self.window else { return }
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        self.window = window
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.windowDidUpdate()
            }
        }
        windowDidUpdate()
    }

    private func windowDidUpdate() {
        guard let window else { return }
        guard isSuppressed() else {
            // Shown on purpose (unlocked, recovery, the Touch ID offer): opaque again.
            if window.alphaValue != 1 {
                window.alphaValue = 1
            }
            return
        }
        window.alphaValue = 0
        if window.isVisible {
            suppress(window)
        }
    }
}
