import CoreGraphics
import VaultCore

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
        // MARK: Windows

        static let windowMinWidth: CGFloat = 900
        static let windowMinHeight: CGFloat = 600
        static let windowDefaultWidth: CGFloat = 1_120
        static let windowDefaultHeight: CGFloat = 720
        static let settingsWidth: CGFloat = 560
        static let settingsMinHeight: CGFloat = 360
        static let sheetWidth: CGFloat = 440

        // MARK: Onboarding, lock and recovery

        /// Width of the centered card used by onboarding, lock and recovery screens.
        static let cardWidth: CGFloat = 520
        static let heroIconSize: CGFloat = 40
        static let stepIndicatorDotSize: CGFloat = 6
        static let strengthBarHeight: CGFloat = 4
        /// Recovery key grid: the 14 groups are shown on two rows (§5.3).
        static let recoveryKeyRows = 2
        static let recoveryKeyColumns = Limits.recoveryKeyGroupCount / recoveryKeyRows
        static let recoveryGroupFieldWidth: CGFloat = 88
        static let secretEditorMinHeight: CGFloat = 96

        // MARK: Main window

        static let sidebarMinWidth: CGFloat = 220
        static let sidebarIdealWidth: CGFloat = 260
        static let scopeListMinWidth: CGFloat = 200
        static let scopeListIdealWidth: CGFloat = 220
        static let detailMinWidth: CGFloat = 420
        static let tableNameMinWidth: CGFloat = 160
        static let tableValueMinWidth: CGFloat = 180
        static let tableDateMinWidth: CGFloat = 110
        static let tableStatusMinWidth: CGFloat = 96
        static let statusDotSize: CGFloat = 6
        static let chipHorizontalPadding: CGFloat = 6
        static let chipVerticalPadding: CGFloat = 2
        static let emptyStateIconSize: CGFloat = 32
        static let emptyStateMaxWidth: CGFloat = 360
    }

    /// Opacity levels for tinted backgrounds and dimmed content.
    enum Opacity {
        static let chipBackground: Double = 0.15
        static let cardBorder: Double = 0.08
        static let disabled: Double = 0.45
    }
}
