import CoreGraphics

/// Where the notch island sits (1.0 brief, "Unlock from the notch"): grown out of the notch at
/// the top center of the screen, or floating under the menu bar on a screen without one.
enum NotchGeometry {
    /// - Parameters:
    ///   - notchHeight: the screen's top safe-area inset; 0 without a notch.
    static func islandFrame(size: CGSize, screenFrame: CGRect, visibleFrame: CGRect, notchHeight: CGFloat) -> CGRect {
        let top = notchHeight > 0 ? screenFrame.maxY : visibleFrame.maxY - Theme.Layout.islandMenuBarGap
        return CGRect(
            x: (screenFrame.midX - size.width / 2).rounded(),
            y: top - size.height,
            width: size.width,
            height: size.height
        )
    }
}
