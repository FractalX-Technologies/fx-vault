import AppKit
import SwiftUI

/// The desktop behind the main window, blurred (1.0.2, Cursor-like): an `NSVisualEffectView`
/// blending behind the window. The ground and the sidebar pane tint it with their colors at
/// ``WindowGlass/opacity(_:reduceTransparency:)``.
struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        // Active even while another app is in front: the window would turn flat grey otherwise.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

enum WindowGlass {
    /// The tints over the blur, as Cursor's: the sidebar shows the desktop, the ground barely.
    static let ground: Double = 0.68
    static let sidebar: Double = 0.32
    /// The notch island's black over the blur; the band beside the notch stays solid.
    static let island: Double = 0.6

    /// Reduce Transparency asks for solid colors: the tint becomes opaque.
    static func opacity(_ tint: Double, reduceTransparency: Bool) -> Double {
        reduceTransparency ? 1 : tint
    }
}
