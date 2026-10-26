import AppKit
import SwiftUI

/// Makes a ``NotchIslandPanel`` around a root view and places it as the island is
/// (``NotchGeometry``): the island and the quick vault (1.0 Q1) share it.
@MainActor
final class NotchPanelPresenter {
    private(set) var panel: NotchIslandPanel?
    private let hasShadow: Bool
    private let notchHeight: () -> CGFloat
    private let content: () -> AnyView

    /// - Parameters:
    ///   - hasShadow: the quick vault opens over other apps' windows and needs its edge.
    ///   - notchHeight: the root view's notch height, read each time the panel is placed.
    init<Content: View>(hasShadow: Bool = false, notchHeight: @escaping () -> CGFloat, content: @escaping () -> Content) {
        self.hasShadow = hasShadow
        self.notchHeight = notchHeight
        self.content = { AnyView(content()) }
    }

    /// The main screen's notch height; 0 floats the panel under the menu bar.
    static var screenNotchHeight: CGFloat {
        (NSScreen.main ?? NSScreen.screens.first)?.safeAreaInsets.top ?? 0
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    /// Places the panel (made on first use) at its content's size, then gives it the keys.
    func show() {
        let panel = panel ?? makePanel()
        place(size: panel.contentView?.fittingSize ?? .zero)
        panel.makeKeyAndOrderFront(nil)
    }

    /// `dropping`: the next show draws a new panel, so no old frame flashes when it reopens.
    func hide(dropping: Bool = false) {
        panel?.orderOut(nil)
        if dropping {
            panel = nil
        }
    }

    /// The content's size changed; the panel keeps its top edge.
    func place(size: CGSize) {
        guard let panel, size.width > 0, size.height > 0,
              let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = NotchGeometry.islandFrame(
            size: size,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            notchHeight: notchHeight()
        )
        panel.setFrame(frame, display: true)
    }

    private func makePanel() -> NotchIslandPanel {
        let panel = NotchIslandPanel()
        panel.hasShadow = hasShadow
        let hosting = NSHostingView(rootView: content())
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.panel = panel
        return panel
    }
}
