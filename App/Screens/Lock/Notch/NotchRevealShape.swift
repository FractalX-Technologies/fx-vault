import SwiftUI

/// The island's outline as it grows out of the notch: at 0 the notch itself (its width and
/// height, centered, hung from the top), at 1 the whole island. Animatable, so a spring on
/// ``NotchIslandModel/isRevealed`` draws every frame in between.
nonisolated struct NotchRevealShape: Shape {
    var progress: CGFloat
    let startWidth: CGFloat
    let startHeight: CGFloat
    let topRadius: CGFloat
    /// The hardware notch's lower corners, where it starts.
    let startRadius: CGFloat
    let radius: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let outline = Self.outline(progress: progress, in: rect, startWidth: startWidth, startHeight: startHeight)
        let reveal = min(max(progress, 0), 1)
        // The notch's own lower corners are small; they round out as the island grows.
        let bottom = min(radius * reveal + startRadius * (1 - reveal), outline.height / 2)
        return UnevenRoundedRectangle(
            topLeadingRadius: min(topRadius, outline.height / 2),
            bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom,
            topTrailingRadius: min(topRadius, outline.height / 2)
        )
        .path(in: outline)
    }

    /// Clamped to `rect`: a spring's overshoot past 1 would draw outside the panel.
    static func outline(progress: CGFloat, in rect: CGRect, startWidth: CGFloat, startHeight: CGFloat) -> CGRect {
        let reveal = min(max(progress, 0), 1)
        let width = startWidth + (rect.width - startWidth) * reveal
        let height = startHeight + (rect.height - startHeight) * reveal
        return CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: height)
    }
}
