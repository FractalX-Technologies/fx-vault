import SwiftUI

/// A floating panel of the main window (1.0 D6c2b; board Main2-Home): Liquid Glass in a rounded
/// rectangle, a hairline border and the panel shadow. The sidebar and the toolbar use `panel`
/// (14 pt) corners, the recovery-key strip `row` (10 pt).
private struct GlassPanel: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .glassEffect(.regular, in: shape)
            .overlay(shape.strokeBorder(Theme.Colors.hairline, lineWidth: Theme.Stroke.hairline))
            .shadow(color: Theme.Colors.panelShadow, radius: Theme.Shadow.panelRadius, x: 0, y: Theme.Shadow.panelY)
    }
}

extension View {
    /// Floats the view on the main window's ground as a glass panel.
    func fxGlassPanel(radius: CGFloat = Theme.Radius.panel) -> some View {
        modifier(GlassPanel(radius: radius))
    }
}

/// The main window's soft ground (board Main2-Home): `mainGround`, lit from each corner by a glow
/// that fades out `groundGlowRadius` in. The panels float on it; the other windows keep `ground`.
struct MainWindowGround: View {
    var body: some View {
        ZStack {
            Theme.Colors.mainGround
            glow(Theme.Colors.mainGlowTopLeading, from: .topLeading)
            glow(Theme.Colors.mainGlowTopTrailing, from: .topTrailing)
            glow(Theme.Colors.mainGlowBottomTrailing, from: .bottomTrailing)
            glow(Theme.Colors.mainGlowBottomLeading, from: .bottomLeading)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func glow(_ color: Color, from corner: UnitPoint) -> some View {
        RadialGradient(
            colors: [color, color.opacity(0)],
            center: corner,
            startRadius: 0,
            endRadius: Theme.Layout.groundGlowRadius
        )
    }
}
