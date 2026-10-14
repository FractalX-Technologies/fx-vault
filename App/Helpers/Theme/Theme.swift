import CoreGraphics

/// FX Vault design system. Every color, font, spacing, radius and duration used by
/// the UI comes from `Theme`; views never hardcode them.
///
/// - `Theme.Colors`: semantic colors from Assets.xcassets (light and dark variants)
/// - `Theme.Typography`: text styles
/// - `Theme.Spacing`, `Theme.Radius`: layout metrics
/// - `Theme.Durations`: animation timings
/// - `Theme.Layout`: window and component sizes
enum Theme {
    enum Layout {
        static let windowMinWidth: CGFloat = 900
        static let windowMinHeight: CGFloat = 600
        static let windowDefaultWidth: CGFloat = 1_120
        static let windowDefaultHeight: CGFloat = 720
        static let settingsWidth: CGFloat = 480
        static let placeholderIconSize: CGFloat = 44
    }
}
