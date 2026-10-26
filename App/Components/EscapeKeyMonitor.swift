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
            // Starts when the view moves into a window: a view brought back with the same
            // identity (no new move) has no esc. The palette is a new view each time it opens.
            .background(WindowAccessor { window in
                monitor.start(in: window, action: action)
            })
            .onDisappear {
                monitor.stop()
            }
    }
}

/// Which key-down is the esc that runs the action.
enum EscapeKey {
    /// Esc without ⌘ ⌥ ⌃ ⇧ in the watched window. Caps Lock, fn and the keypad flags are not
    /// modifiers here; esc that ends an input method's composition is left to the field.
    static func runsAction(keyCode: UInt16, flags: NSEvent.ModifierFlags, hasMarkedText: Bool, isWatchedWindow: Bool) -> Bool {
        keyCode == UInt16(kVK_Escape)
            && flags.isDisjoint(with: [.command, .option, .control, .shift])
            && !hasMarkedText
            && isWatchedWindow
    }
}

private final class EscapeMonitor {
    private var token: Any?
    private weak var window: NSWindow?

    func start(in window: NSWindow, action: @escaping () -> Void) {
        stop()
        self.window = window
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated {
                guard let self, let window = self.window else { return false }
                let editor = window.firstResponder as? NSTextView
                guard EscapeKey.runsAction(
                    keyCode: keyCode,
                    flags: flags,
                    hasMarkedText: editor?.hasMarkedText() == true,
                    isWatchedWindow: window.windowNumber == windowNumber
                ) else { return false }
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

    // A skipped `onDisappear` must not leave the monitor, and the action's captures, alive.
    isolated deinit {
        stop()
    }
}

extension View {
    /// Esc anywhere in the view's window runs `action` (the ⌘K palette's close).
    func onEscapeKey(perform action: @escaping () -> Void) -> some View {
        modifier(EscapeKeyMonitor(action: action))
    }
}
