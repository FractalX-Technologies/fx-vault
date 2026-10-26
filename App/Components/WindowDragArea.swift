import AppKit
import SwiftUI

/// Part of the main window's chrome that acts as its title bar (1.0 D6c2b): the gutters, the
/// sidebar's top band and the toolbar panel's empty part. Dragging moves the window, a
/// double-click does what System Settings › Desktop & Dock says, and the first click in an
/// inactive window counts. Views in front of it (text, buttons, glass panels) keep their clicks.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragAreaView {
        DragAreaView()
    }

    func updateNSView(_ view: DragAreaView, context: Context) {}

    final class DragAreaView: NSView {
        // Only the chrome takes the activating click; the toolbar's buttons don't.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                TitleBarDoubleClickAction.current.perform(on: window)
            } else {
                window.performDrag(with: event)
            }
        }
    }
}

/// What a double-click on a title bar does. AppKit only does it in its own title bar, which the
/// main window hides under its panels.
enum TitleBarDoubleClickAction: Equatable {
    case zoom
    case minimize
    case none

    /// System Settings › Desktop & Dock › "Double-click a window's title bar to": Fill and Zoom
    /// both zoom (a window's standard frame fills the screen), Minimize, or Do Nothing.
    static func resolve(actionOnDoubleClick: String?, minimizesOnDoubleClick: Bool) -> Self {
        switch actionOnDoubleClick {
        case "Minimize": .minimize
        case "None": .none
        case nil: minimizesOnDoubleClick ? .minimize : .zoom
        default: .zoom
        }
    }

    static var current: Self {
        let defaults = UserDefaults.standard
        return resolve(
            actionOnDoubleClick: defaults.string(forKey: "AppleActionOnDoubleClick"),
            minimizesOnDoubleClick: defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick")
        )
    }

    func perform(on window: NSWindow) {
        switch self {
        case .zoom: window.performZoom(nil)
        case .minimize: window.performMiniaturize(nil)
        case .none: break
        }
    }
}
