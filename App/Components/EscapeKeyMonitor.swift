import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Runs an action on esc in the view's window while the view is on screen, before the window
/// dispatches the key. A focused text field's editor turns esc into `cancelOperation:` and eats
/// it, so neither `onKeyPress(.escape)` nor `onExitCommand` on the field sees it (UI test
/// `JumpPaletteUITests`). Esc that ends an input method's composition is left to the field.
private struct EscapeKeyMonitor: ViewModifier {
    let action: () -> Void
    @State private var monitor = EscapeMonitor()

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor { window in
                monitor.start(in: window, action: action)
            })
            .onDisappear {
                monitor.stop()
            }
    }
}

private final class EscapeMonitor {
    private var token: Any?
    private weak var window: NSWindow?

    func start(in window: NSWindow, action: @escaping () -> Void) {
        stop()
        self.window = window
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isPlainEscape = event.keyCode == UInt16(kVK_Escape)
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            let windowNumber = event.windowNumber
            let handled = isPlainEscape && MainActor.assumeIsolated {
                guard let self, let window = self.window, window.windowNumber == windowNumber else { return false }
                if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
                action()
                return true
            }
            return handled ? nil : event
        }
    }

    func stop() {
        if let token {
            NSEvent.removeMonitor(token)
        }
        token = nil
    }
}

extension View {
    /// Esc anywhere in the view's window runs `action` (the ⌘K palette's close).
    func onEscapeKey(perform action: @escaping () -> Void) -> some View {
        modifier(EscapeKeyMonitor(action: action))
    }
}
