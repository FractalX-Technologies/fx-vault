import CoreGraphics

extension Theme {
    /// Spacing scale on a 2-point grid (docs/DESIGN.md, "Spacing"). The mockup's in-between
    /// steps (10, 20, 28) have their own names so screens never write a literal.
    enum Spacing {
        static let xxSmall: CGFloat = 2
        static let xSmall: CGFloat = 4
        /// 6: chip dot to text, label to field.
        static let smallMinus: CGFloat = 6
        static let small: CGFloat = 8
        /// 10: icon to text in rows and buttons, gaps between pills.
        static let mediumMinus: CGFloat = 10
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        /// 20: table cell insets, gaps between stacked blocks in the detail column.
        static let largePlus: CGFloat = 20
        static let xLarge: CGFloat = 24
        /// 28: the detail column's top inset, hero gaps on lock and onboarding.
        static let xLargePlus: CGFloat = 28
        static let xxLarge: CGFloat = 32
        /// 36: the detail column's side inset.
        static let xxLargePlus: CGFloat = 36
        static let xxxLarge: CGFloat = 48
        /// 56 and 64: onboarding and lock page insets.
        static let huge: CGFloat = 56
        static let xHuge: CGFloat = 64
    }
}
