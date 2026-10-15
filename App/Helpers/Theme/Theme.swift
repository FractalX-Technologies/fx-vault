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

        // MARK: Editor sheets (item editor, environment sheets)

        /// Wider than `sheetWidth`: a grouped form with the value editor or the branch rules.
        static let editorSheetWidth: CGFloat = 520

        // MARK: New Repository sheet

        /// A full form: owner, name, contents, environments and items.
        static let createRepoSheetWidth: CGFloat = 560
        static let createRepoSheetHeight: CGFloat = 640
        /// Height of the loading and failure states.
        static let createRepoStatusHeight: CGFloat = 320
        /// Width of the nested item and environment editors.
        static let createRepoEditorWidth: CGFloat = 480

        // MARK: Sync sheet

        /// Wide enough for "Delete N Items on GitHub" next to the other footer buttons and for a
        /// scope line with its item names.
        static let syncSheetWidth: CGFloat = 620
        static let syncSheetMinHeight: CGFloat = 360
        static let syncSheetIdealHeight: CGFloat = 520
        /// The progress bar's width in the progress step.
        static let syncProgressWidth: CGFloat = 360

        // MARK: Drift review sheet

        static let driftSheetWidth: CGFloat = 600
        static let driftSheetMinHeight: CGFloat = 360
        static let driftSheetIdealHeight: CGFloat = 480

        // MARK: .env import and export sheets

        /// The import sheet holds a five-column table.
        static let envImportSheetWidth: CGFloat = 760
        static let envImportSheetHeight: CGFloat = 560
        static let envExportSheetWidth: CGFloat = 520
        /// Height of the paste editor above the live preview.
        static let envPasteEditorHeight: CGFloat = 150
        /// The paste mode shows the editor above the live preview, so the sheet is taller.
        static let envImportPasteSheetHeight: CGFloat = 660
        /// Height of the parse issue list under the import table.
        static let envIssueListMaxHeight: CGFloat = 96
        /// Height of a name list in the export warnings ("Skipped: …").
        static let envNameListMaxHeight: CGFloat = 88
        static let envImportIncludeColumnWidth: CGFloat = 28
        static let envImportLineColumnWidth: CGFloat = 40
        static let envImportKeyColumnMinWidth: CGFloat = 220
        static let envImportKindColumnWidth: CGFloat = 130
        static let envImportConflictColumnWidth: CGFloat = 130

        // MARK: Sharing sheets

        /// Width of every sharing sheet (export, import, nearby send and receive).
        static let shareSheetWidth: CGFloat = 560
        static let shareSheetMinHeight: CGFloat = 420
        /// Height of the scope tree, the import preview and the nearby peer list.
        static let shareListHeight: CGFloat = 260
        /// Width of the per-item action picker in the import preview.
        static let shareActionPickerWidth: CGFloat = 150
        /// Minimum width of each SAS decision button ("Codes match" / "Don't match").
        static let sasButtonMinWidth: CGFloat = 160

        // MARK: Nearby Chat window (v0.2.0)

        static let chatWindowMinWidth: CGFloat = 720
        static let chatWindowMinHeight: CGFloat = 480
        static let chatWindowDefaultWidth: CGFloat = 860
        static let chatWindowDefaultHeight: CGFloat = 600
        /// Width of the "Nearby" people column.
        static let chatPeerListWidth: CGFloat = 240
        /// Widest a message bubble or attachment card grows.
        static let chatBubbleMaxWidth: CGFloat = 420
        /// Height of the message field (about four lines).
        static let chatComposerHeight: CGFloat = 76
        /// The attachment picker sheet and its item list.
        static let chatPickerWidth: CGFloat = 520
        static let chatPickerListHeight: CGFloat = 300
    }

    /// Opacity levels for tinted backgrounds and dimmed content.
    enum Opacity {
        static let chipBackground: Double = 0.15
        static let cardBorder: Double = 0.08
        static let disabled: Double = 0.45
    }
}
