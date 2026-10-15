import SwiftUI

/// The FractalX pill button (docs/DESIGN.md, "Buttons"; mockup Brand, Main, Lock, SyncReview).
///
/// - `.primary`: ink fill, ground text, 500 weight. One per view: the action the screen is for.
/// - `.secondary`: `surface2` fill, ink text. Cancel, Refresh, Touch ID.
/// - `.outline`: hairline-strong border, ink text. Clone, Paste multiple, Back.
/// - `.ghost`: no chrome until hover. Toolbar-like and inline actions.
/// - `.destructive`: danger fill, ground text. Only the final confirm of a destructive action.
///
/// Sizes: `.regular` (34 pt, 13 pt text) and `.large` (42 pt, 14 pt text). Disabled pills fade
/// to 40%; keyboard focus draws a brand ring outside the capsule.
///
/// ```swift
/// Button("Sync 5 changes") { … }
///     .fxButtonStyle(.primary, size: .large)
/// Button("Cancel", role: .cancel) { … }
///     .fxButtonStyle(.secondary, size: .large)
/// ```
struct FXButtonStyle: ButtonStyle {
    enum Variant: CaseIterable, Sendable {
        case primary
        case secondary
        case outline
        case ghost
        case destructive
    }

    enum Size: CaseIterable, Sendable {
        case regular
        case large
    }

    /// The colors of a variant, resolved per state (pure, for tests and previews).
    struct Palette: Equatable {
        let fill: Color?
        let foreground: Color
        let border: Color?
    }

    let variant: Variant
    let size: Size
    let isFullWidth: Bool
    /// Overrides the horizontal padding (the toolbar Sync pill hugs its badge).
    let horizontalPadding: (leading: CGFloat, trailing: CGFloat)?

    init(
        _ variant: Variant = .primary,
        size: Size = .regular,
        isFullWidth: Bool = false,
        horizontalPadding: (leading: CGFloat, trailing: CGFloat)? = nil
    ) {
        self.variant = variant
        self.size = size
        self.isFullWidth = isFullWidth
        self.horizontalPadding = horizontalPadding
    }

    func makeBody(configuration: Configuration) -> some View {
        FXButtonBody(style: self, configuration: configuration)
    }

    // MARK: Resolution (pure)

    static func palette(for variant: Variant, isHovered: Bool) -> Palette {
        switch variant {
        case .primary:
            Palette(fill: Theme.Colors.ink, foreground: Theme.Colors.onInk, border: nil)
        case .secondary:
            // The hairline defines the pill on a dark `card`, where `surface2` is only 1.1:1.
            Palette(fill: Theme.Colors.surface2, foreground: Theme.Colors.ink, border: Theme.Colors.hairline)
        case .outline:
            Palette(fill: isHovered ? Theme.Colors.surface : nil, foreground: Theme.Colors.ink, border: Theme.Colors.hairlineStrong)
        case .ghost:
            Palette(fill: isHovered ? Theme.Colors.surface2 : nil, foreground: Theme.Colors.ink, border: nil)
        case .destructive:
            Palette(fill: Theme.Colors.danger, foreground: Theme.Colors.onInk, border: nil)
        }
    }

    static func height(for size: Size) -> CGFloat {
        switch size {
        case .regular: Theme.Layout.buttonHeightRegular
        case .large: Theme.Layout.buttonHeightLarge
        }
    }

    static func padding(for size: Size) -> CGFloat {
        switch size {
        case .regular: Theme.Layout.buttonPaddingRegular
        case .large: Theme.Layout.buttonPaddingLarge
        }
    }

    static func font(for variant: Variant, size: Size) -> Font {
        let isEmphasized = variant == .primary || variant == .destructive
        switch size {
        case .regular: return isEmphasized ? Theme.Typography.calloutEmphasized : Theme.Typography.callout
        case .large: return isEmphasized ? Theme.Typography.bodyEmphasized : Theme.Typography.body
        }
    }

    /// Ink and danger fills dim on hover; the others gain a fill instead.
    static func hoverOpacity(for variant: Variant, isHovered: Bool) -> Double {
        guard isHovered else { return 1 }
        switch variant {
        case .primary, .destructive: return Theme.Opacity.hovered
        case .secondary, .outline, .ghost: return 1
        }
    }
}

private struct FXButtonBody: View {
    let style: FXButtonStyle
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    var body: some View {
        let palette = FXButtonStyle.palette(for: style.variant, isHovered: isHovered && isEnabled)
        let basePadding = FXButtonStyle.padding(for: style.size)
        configuration.label
            .font(FXButtonStyle.font(for: style.variant, size: style.size))
            .lineLimit(1)
            // A pill never truncates or compresses its title next to flexible text.
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(palette.foreground)
            .padding(.leading, style.horizontalPadding?.leading ?? basePadding)
            .padding(.trailing, style.horizontalPadding?.trailing ?? basePadding)
            .frame(height: FXButtonStyle.height(for: style.size))
            .frame(maxWidth: style.isFullWidth ? .infinity : nil)
            .background {
                if let fill = palette.fill {
                    Capsule.pill.fill(fill)
                }
            }
            .overlay {
                if let border = palette.border {
                    Capsule.pill.strokeBorder(border, lineWidth: Theme.Stroke.hairline)
                }
            }
            .overlay {
                if isFocused {
                    Capsule.pill
                        .strokeBorder(Theme.Colors.brand, lineWidth: Theme.Layout.focusRingWidth)
                        .padding(-(Theme.Layout.focusRingWidth + Theme.Layout.focusRingOffset))
                }
            }
            .contentShape(.pill)
            .opacity(configuration.isPressed ? Theme.Opacity.pressed : FXButtonStyle.hoverOpacity(for: style.variant, isHovered: isHovered))
            .opacity(isEnabled ? 1 : Theme.Opacity.disabled)
            .onHover { isHovered = $0 }
            .animation(Theme.Durations.interactionAnimation, value: isHovered)
            .animation(Theme.Durations.interactionAnimation, value: configuration.isPressed)
    }
}

/// A 32 pt circular icon button (mockup toolbar: New repository, Share, Lock; the eye that
/// reveals a value uses `.ghost`). Always give the button an accessibility label.
struct FXIconButtonStyle: ButtonStyle {
    enum Variant: Sendable {
        /// Hairline circle (toolbar-style).
        case outline
        /// No chrome until hover (inline, in table cells).
        case ghost
    }

    let variant: Variant

    init(_ variant: Variant = .outline) {
        self.variant = variant
    }

    func makeBody(configuration: Configuration) -> some View {
        FXIconButtonBody(variant: variant, configuration: configuration)
    }
}

private struct FXIconButtonBody: View {
    let variant: FXIconButtonStyle.Variant
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(Theme.Typography.callout)
            .foregroundStyle(variant == .ghost && !isHovered ? Theme.Colors.subtleText : Theme.Colors.ink)
            .frame(width: Theme.Layout.iconButtonSize, height: Theme.Layout.iconButtonSize)
            .background {
                if isHovered && isEnabled {
                    Circle().fill(Theme.Colors.surface2)
                }
            }
            .overlay {
                if variant == .outline {
                    Circle().strokeBorder(Theme.Colors.hairline, lineWidth: Theme.Stroke.hairline)
                }
            }
            .overlay {
                if isFocused {
                    Circle()
                        .strokeBorder(Theme.Colors.brand, lineWidth: Theme.Layout.focusRingWidth)
                        .padding(-(Theme.Layout.focusRingWidth + Theme.Layout.focusRingOffset))
                }
            }
            .contentShape(Circle())
            .opacity(configuration.isPressed ? Theme.Opacity.pressed : 1)
            .opacity(isEnabled ? 1 : Theme.Opacity.disabled)
            .onHover { isHovered = $0 }
            .animation(Theme.Durations.interactionAnimation, value: isHovered)
    }
}

extension View {
    /// Applies ``FXButtonStyle`` and hides the system focus ring, which the style replaces with
    /// its own brand ring. Prefer this over `.buttonStyle(FXButtonStyle(…))`.
    func fxButtonStyle(_ variant: FXButtonStyle.Variant = .primary, size: FXButtonStyle.Size = .regular, isFullWidth: Bool = false) -> some View {
        buttonStyle(FXButtonStyle(variant, size: size, isFullWidth: isFullWidth))
            .focusEffectDisabled()
    }

    /// Applies ``FXIconButtonStyle`` and hides the system focus ring (the style draws its own).
    func fxIconButtonStyle(_ variant: FXIconButtonStyle.Variant = .outline) -> some View {
        buttonStyle(FXIconButtonStyle(variant))
            .focusEffectDisabled()
    }
}

#Preview("Buttons") {
    VStack(alignment: .leading, spacing: Theme.Spacing.large) {
        ForEach(FXButtonStyle.Size.allCases, id: \.self) { size in
            HStack(spacing: Theme.Spacing.mediumMinus) {
                Button {} label: { Text(verbatim: "Primary") }.fxButtonStyle(.primary, size: size)
                Button {} label: { Text(verbatim: "Secondary") }.fxButtonStyle(.secondary, size: size)
                Button {} label: { Text(verbatim: "Outline") }.fxButtonStyle(.outline, size: size)
                Button {} label: { Text(verbatim: "Ghost") }.fxButtonStyle(.ghost, size: size)
                Button {} label: { Text(verbatim: "Delete") }.fxButtonStyle(.destructive, size: size)
                Button {} label: { Text(verbatim: "Disabled") }.fxButtonStyle(.primary, size: size).disabled(true)
            }
        }
        HStack {
            Button {} label: { Label { Text(verbatim: "Lock") } icon: { Image(systemName: "lock") } }.fxIconButtonStyle()
            Button {} label: { Label { Text(verbatim: "Reveal") } icon: { Image(systemName: "eye") } }.fxIconButtonStyle(.ghost)
        }
    }
    .padding(Theme.Spacing.xxLarge)
    .background(Theme.Colors.ground)
}
