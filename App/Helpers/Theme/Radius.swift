import SwiftUI

extension Theme {
    /// Corner radii (docs/DESIGN.md, "Shape"). Pills (buttons, chips, the segmented control,
    /// pill inputs, badges) use the `.pill` capsule, not a radius.
    enum Radius {
        /// Cards and in-window sheets.
        static let card: CGFloat = 24
        /// Sheets drawn in the window (the system sheet keeps its own corners).
        static let sheet: CGFloat = 24
        /// Tables and grouped lists inside a card or on the ground.
        static let container: CGFloat = 16
        /// Rounded inputs, banners, checkbox rows.
        static let control: CGFloat = 12
        /// Scope rows, color swatches.
        static let row: CGFloat = 10
        /// Sidebar repository rows (32 pt tall).
        static let compactRow: CGFloat = 8

        // MARK: Legacy names (v0.2 screens)

        static let small: CGFloat = 4
        /// Legacy name of ``compactRow``.
        static let medium: CGFloat = compactRow
        /// Legacy name of ``control``.
        static let large: CGFloat = control
    }
}

extension Shape where Self == Capsule {
    /// The FractalX pill: a capsule with circular ends. Use it instead of `Capsule.pill`: since the
    /// macOS 27 SDK `Capsule.pill` defaults to `.continuous` corners, whose flatter ends read as
    /// short straight edges on 22–44 pt pills and chips.
    static var pill: Capsule {
        Capsule(style: .circular)
    }
}
