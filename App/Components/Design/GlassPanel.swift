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

/// The main window's sidebar as a pane (1.0.2, Cursor-like): flush with the window's edges, with
/// a hairline at its trailing edge. Its tint is ``MainWindowGround``'s, so the glass under it is
/// not tinted twice.
private struct SidebarPane: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Theme.Colors.hairline)
                    .frame(width: Theme.Stroke.hairline)
                    .accessibilityHidden(true)
            }
    }
}

extension View {
    func fxSidebarPane() -> some View {
        modifier(SidebarPane())
    }
}

/// The main window's soft ground (board Main2-Home): the blurred desktop (``BehindWindowBlur``,
/// 1.0.2) tinted `surface` under the sidebar (`sidebarWidth`, nil without one) and `mainGround`
/// beside it, lit from each corner by a glow that fades out `groundGlowRadius` in (light only).
/// The other windows keep `ground`.
struct MainWindowGround: View {
    var sidebarWidth: CGFloat?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            BehindWindowBlur()
            HStack(spacing: 0) {
                if let sidebarWidth {
                    Theme.Colors.surface
                        .opacity(WindowGlass.opacity(WindowGlass.sidebar, reduceTransparency: reduceTransparency))
                        .frame(width: sidebarWidth)
                }
                Theme.Colors.mainGround.opacity(tint)
            }
            glow(Theme.Colors.mainGlowTopLeading, from: .topLeading)
            glow(Theme.Colors.mainGlowTopTrailing, from: .topTrailing)
            glow(Theme.Colors.mainGlowBottomTrailing, from: .bottomTrailing)
            glow(Theme.Colors.mainGlowBottomLeading, from: .bottomLeading)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var tint: Double {
        WindowGlass.opacity(WindowGlass.ground, reduceTransparency: reduceTransparency)
    }

    // At the ground's tint too: an opaque glow would hide the glass in its corner.
    private func glow(_ color: Color, from corner: UnitPoint) -> some View {
        RadialGradient(
            colors: [color.opacity(tint), color.opacity(0)],
            center: corner,
            startRadius: 0,
            endRadius: Theme.Layout.groundGlowRadius
        )
    }
}
