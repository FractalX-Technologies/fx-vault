import SwiftUI

/// The dotted ground behind the lock screen (mockup Lock): the `ground` color with a dot every
/// 22 pt. Decorative; it never carries information.
///
/// ```swift
/// LockContent()
///     .frame(maxWidth: .infinity, maxHeight: .infinity)
///     .background(DotGridBackground())
/// ```
struct DotGridBackground: View {
    var spacing: CGFloat = Theme.Layout.dotGridSpacing
    var dotDiameter: CGFloat = Theme.Layout.dotGridDotDiameter

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            context.fill(Self.dotsPath(in: CGRect(origin: .zero, size: size), spacing: spacing, diameter: dotDiameter), with: .color(Theme.Colors.dotGrid))
        }
        .background(Theme.Colors.ground)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// One dot centered in every `spacing`-sized tile of `rect` (as CSS draws a radial-gradient
    /// tile).
    static func dotsPath(in rect: CGRect, spacing: CGFloat, diameter: CGFloat) -> Path {
        var path = Path()
        guard spacing > 0, rect.width > 0, rect.height > 0 else { return path }
        let half = spacing / 2
        var y = rect.minY + half
        while y < rect.maxY {
            var x = rect.minX + half
            while x < rect.maxX {
                path.addEllipse(in: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter))
                x += spacing
            }
            y += spacing
        }
        return path
    }
}

#Preview {
    DotGridBackground()
        .frame(width: Theme.Layout.cardWidth, height: Theme.Layout.cardWidth)
}
