import SwiftUI

/// The FractalX card: `card` fill, 1 pt hairline border, no shadow (docs/DESIGN.md, "Cards").
///
/// - `.card`: 24 pt corners. Onboarding and lock panels, settings groups, empty states.
/// - `.container`: 16 pt corners, no padding. Tables and grouped lists (mockup Main table,
///   SyncReview scope list); rows inside draw their own hairline dividers.
/// - `.sheet`: 24 pt corners, hairline-strong border and the one soft shadow. A dialog drawn
///   inside the window. System `.sheet`s keep their own chrome: give their content
///   `.fxSheetBackground()` instead.
/// - `.popover`: 16 pt corners, no padding, hairline-strong border, the soft shadow and a blur
///   behind the fill, so the text under it does not show through. The ⌘K jump palette over the
///   window (board Main2-Search).
///
/// ```swift
/// Card {
///     SectionLabel("Review before sync")
///     Text(title).fxTextStyle(.title)
/// }
/// Card(.container, padding: 0) { ForEach(rows) { … } }
/// ```
struct Card<Content: View>: View {
    typealias Style = CardStyle

    let style: Style
    let padding: CGFloat
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(
        _ style: Style = .card,
        padding: CGFloat? = nil,
        spacing: CGFloat = Theme.Spacing.large,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.style = style
        self.padding = padding ?? Self.defaultPadding(for: style)
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content()
        }
        .padding(padding)
        .fxCardBackground(style)
    }

    static func defaultPadding(for style: Style) -> CGFloat {
        switch style {
        case .card, .sheet: Theme.Spacing.xxLarge
        case .container, .popover: 0
        }
    }
}

/// The card treatments (see ``Card``).
enum CardStyle: Sendable {
    case card
    case container
    case sheet
    case popover

    var radius: CGFloat {
        switch self {
        case .card, .sheet: Theme.Radius.card
        case .container, .popover: Theme.Radius.container
        }
    }

    /// Dialogs over the window stand out with the stronger border and the one soft shadow.
    var floatsOverContent: Bool {
        self == .sheet || self == .popover
    }

    /// The palette floats over the window's text under a light scrim (board Main2-Search:
    /// white at 94% over a backdrop blur).
    var blursBehind: Bool {
        self == .popover
    }
}

private struct CardBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    let border: Color
    let hasShadow: Bool
    let blursBehind: Bool

    func body(content: Content) -> some View {
        content
            .background(Theme.Colors.card, in: shape)
            .background(blursBehind ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.clear), in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(border, lineWidth: Theme.Stroke.hairline))
            .shadow(
                color: hasShadow ? Theme.Colors.shadow : Color.clear,
                radius: hasShadow ? Theme.Shadow.sheetRadius : 0,
                x: 0,
                y: hasShadow ? Theme.Shadow.sheetY : 0
            )
    }
}

extension View {
    /// Draws the card background, border and (for `.sheet` and `.popover`) shadow behind any view.
    func fxCardBackground(_ style: CardStyle = .card) -> some View {
        modifier(CardBackground(
            shape: RoundedRectangle(cornerRadius: style.radius, style: .continuous),
            border: style.floatsOverContent ? Theme.Colors.hairlineStrong : Theme.Colors.hairline,
            hasShadow: style.floatsOverContent,
            blursBehind: style.blursBehind
        ))
    }

    /// The background of a system sheet's content: the card color, edge to edge.
    func fxSheetBackground() -> some View {
        background(Theme.Colors.card)
            .presentationBackground(Theme.Colors.card)
    }
}

/// A 1 pt hairline divider (horizontal by default), for rows inside a `.container` card.
struct HairlineDivider: View {
    var axis: Axis = .horizontal
    var isStrong = false

    var body: some View {
        let color = isStrong ? Theme.Colors.hairlineStrong : Theme.Colors.hairline
        switch axis {
        case .horizontal:
            Rectangle().fill(color).frame(height: Theme.Stroke.hairline)
        case .vertical:
            Rectangle().fill(color).frame(width: Theme.Stroke.hairline)
        }
    }
}

#Preview {
    VStack(spacing: Theme.Spacing.xLarge) {
        Card {
            SectionLabel("Review before sync")
            Text(verbatim: "5 changes to owner-a/fx-vault").fxTextStyle(.title)
        }
        Card(.container) {
            Text(verbatim: "DATABASE_URL").fxTextStyle(.monoName).padding(Theme.Spacing.largePlus)
            HairlineDivider()
            Text(verbatim: "SENTRY_DSN").fxTextStyle(.monoName).padding(Theme.Spacing.largePlus)
        }
        Card(.sheet) {
            Text(verbatim: "Sheet").fxTextStyle(.title2)
        }
    }
    .padding(Theme.Spacing.xxxLarge)
    .background(Theme.Colors.ground)
}
