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
    }
}
