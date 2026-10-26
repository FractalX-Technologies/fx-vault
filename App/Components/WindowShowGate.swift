import AppKit

/// Runs an action on a window once it is on screen, keeping it transparent until then.
/// SwiftUI hands the main window to ``WindowAccessor`` before it orders it front, so closing it
/// right away is undone: FX Vault 1.0.0 opened locked with the lock window beside the island.
@MainActor
final class WindowShowGate {
    private weak var window: NSWindow?
    private var action: (() -> Void)?
    private var observer: NSObjectProtocol?

    /// `action` runs now when `window` is already visible, else at its first update on screen
    /// (AppKit updates every visible window once per event loop pass).
    func onScreen(_ window: NSWindow, run action: @escaping () -> Void) {
        cancel()
        guard !window.isVisible else {
            action()
            return
        }
        self.window = window
        self.action = action
        window.alphaValue = 0
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.windowDidUpdate()
            }
        }
    }

    /// Drops a pending action and makes the window opaque again.
    func cancel() {
        removeObserver()
        action = nil
        window?.alphaValue = 1
        window = nil
    }

    private func windowDidUpdate() {
        guard let window, window.isVisible, let action else { return }
        removeObserver()
        self.action = nil
        self.window = nil
        action()
        // After the action: a window it closed comes back opaque when it reopens.
        window.alphaValue = 1
    }

    private func removeObserver() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }
}
