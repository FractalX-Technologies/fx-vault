import SwiftUI

extension Theme {
    /// Text styles. All are Dynamic Type-relative system styles.
    enum Typography {
        static let largeTitle = Font.largeTitle.weight(.semibold)
        static let title = Font.title2.weight(.semibold)
        static let headline = Font.headline
        static let body = Font.body
        static let callout = Font.callout
        static let caption = Font.caption
        /// Secret names, recovery keys, SAS codes and command templates.
        static let monospaced = Font.system(.body, design: .monospaced)
        /// The `ddd ddd` nearby code (§9.4 step 5): large and monospaced so both people can read
        /// it across a desk.
        static let sasCode = Font.system(size: 44, weight: .semibold, design: .monospaced)
    }
}
