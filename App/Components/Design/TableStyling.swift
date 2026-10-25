import SwiftUI

// Table and row styling (docs/DESIGN.md, "Tables and rows"; mockup Main).
//
// The detail table stays a native SwiftUI `Table` (keyboard, selection, context menus); these
// helpers give it the FractalX look: a card container with 16 pt corners and a hairline, no
// alternating rows, 34 pt rows (boards Main2, Org-Visibility), SF Mono names and timestamps.

extension View {
    /// Styles a native `Table`: no alternating rows, transparent scroll background, a `card`
    /// container with 16 pt corners and a hairline border.
    ///
    /// ```swift
    /// Table(rows, selection: $selection) { … }
    ///     .fxTable()
    /// ```
    func fxTable() -> some View {
        tableStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .background(Theme.Colors.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.container, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.container, style: .continuous)
                    .strokeBorder(Theme.Colors.hairline, lineWidth: Theme.Stroke.hairline)
            )
    }

    /// Gives a table cell the design row height (34 pt rows; the cell content is
    /// `tableCellMinHeight` and the table adds its own row insets) and leading alignment. Apply it
    /// to the content of every column of a row, or at least the tallest.
    func fxTableCell() -> some View {
        frame(maxWidth: .infinity, minHeight: Theme.Layout.tableCellMinHeight, alignment: .leading)
    }

    /// The background of a selectable row outside a native `List`/`Table` selection (mockup
    /// sidebar tree and Copy To).
    ///
    /// ```swift
    /// ScopeRow(scope).fxRowBackground(isSelected: scope.id == selection, style: .scope)
    /// ```
    func fxRowBackground(isSelected: Bool, style: FXRowStyle) -> some View {
        modifier(FXRowBackground(isSelected: isSelected, style: style))
    }
}

/// Row treatments of the main window's columns.
enum FXRowStyle: Sendable {
    /// Sidebar tree rows: 28 pt, 8 pt corners, selected = `surface2` fill.
    case sidebar
    /// Scopes: 36 pt, 10 pt corners, selected = `card` fill with a hairline.
    case scope

    var height: CGFloat {
        switch self {
        case .sidebar: Theme.Layout.sidebarRowHeight
        case .scope: Theme.Layout.scopeRowHeight
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .sidebar: Theme.Radius.compactRow
        case .scope: Theme.Radius.row
        }
    }

    func selectedFill() -> Color {
        switch self {
        case .sidebar: Theme.Colors.surface2
        case .scope: Theme.Colors.card
        }
    }

    func selectedBorder() -> Color? {
        switch self {
        case .sidebar: nil
        case .scope: Theme.Colors.hairline
        }
    }
}

private struct FXRowBackground: ViewModifier {
    let isSelected: Bool
    let style: FXRowStyle

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
        content
            .padding(.horizontal, style == .sidebar ? Theme.Spacing.small : Theme.Spacing.mediumMinus)
            .frame(maxWidth: .infinity, minHeight: style.height, alignment: .leading)
            .background {
                if isSelected {
                    shape.fill(style.selectedFill())
                }
            }
            .overlay {
                if isSelected, let border = style.selectedBorder() {
                    shape.strokeBorder(border, lineWidth: Theme.Stroke.hairline)
                }
            }
            .contentShape(shape)
            .animation(Theme.Durations.interactionAnimation, value: isSelected)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A secret or variable name in a table or list: SF Mono 13, one line, truncated in the
/// middle so prefixes and suffixes (`STRIPE_…_KEY`) stay readable.
struct TableNameText: View {
    let name: String
    var isDeleted = false

    var body: some View {
        Text(verbatim: name)
            .fxTextStyle(.monoName)
            .foregroundStyle(isDeleted ? Theme.Colors.subtleText : Theme.Colors.ink)
            .strikethrough(isDeleted)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// Secondary text in a table cell: kind, visibility, timestamps (12 pt sans, muted; boards Main2,
/// Org-Visibility).
struct TableMetaText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .fxTextStyle(.caption)
            .foregroundStyle(Theme.Colors.mutedText)
            .lineLimit(1)
    }
}

/// The mono uppercase header row of a hand-built table (a `Card(.container)` with rows, as in
/// the SyncReview mockup). Native `Table` keeps its system header.
///
/// ```swift
/// Card(.container) {
///     FXTableHeaderRow(titles: [nameTitle, valueTitle])
///     ForEach(rows) { row in …; HairlineDivider() }
/// }
/// ```
struct FXTableHeaderRow: View {
    let titles: [String]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.large) {
                ForEach(Array(titles.enumerated()), id: \.offset) { _, title in
                    SectionLabel(title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, Theme.Spacing.largePlus)
            .padding(.vertical, Theme.Spacing.medium)
            HairlineDivider()
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: Theme.Spacing.large) {
        Card(.container) {
            FXTableHeaderRow(titles: ["Name", "Updated"])
            HStack {
                TableNameText(name: "STRIPE_SECRET_KEY")
                TableMetaText("Oct 15 · 10:42")
            }
            .fxTableCell()
            .padding(.horizontal, Theme.Spacing.largePlus)
        }
        Text(verbatim: "production").fxRowBackground(isSelected: true, style: .scope)
        Text(verbatim: "fx-vault").fxRowBackground(isSelected: true, style: .sidebar)
    }
    .padding(Theme.Spacing.xxLarge)
    .background(Theme.Colors.ground)
}
