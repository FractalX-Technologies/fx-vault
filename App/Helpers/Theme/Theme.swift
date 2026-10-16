import CoreGraphics
import VaultCore

/// FX Vault design system. Every color, font, spacing, radius and duration used by
/// the UI comes from `Theme`; views never hardcode them.
///
/// The FractalX design language is documented in docs/DESIGN.md.
///
/// - `Theme.Colors`: semantic colors from Assets.xcassets (light and dark variants)
/// - `Theme.Typography`: Geist fonts; `Theme.TextStyle`: font + tracking + case (`.fxTextStyle`)
/// - `Theme.Spacing`, `Theme.Radius`: layout metrics
/// - `Theme.Durations`: motion (140 ms, spring)
/// - `Theme.Layout`: window and component sizes
/// - `Theme.Opacity`, `Theme.Stroke`, `Theme.Shadow`: states, lines and the one sheet shadow
enum Theme {
    enum Layout {
        // MARK: Design components (App/Components/Design)

        /// Pill button heights: `.regular` (toolbar, inline, table headers) and `.large` (sheet
        /// footers, onboarding, lock).
        static let buttonHeightRegular: CGFloat = 34
        static let buttonHeightLarge: CGFloat = 42
        static let buttonPaddingRegular: CGFloat = 16
        static let buttonPaddingLarge: CGFloat = 22
        /// Circular icon buttons (toolbar-style New, Share, Lock).
        static let iconButtonSize: CGFloat = 32
        /// Text fields and secure fields.
        static let inputHeight: CGFloat = 44
        /// The count badge in the toolbar Sync pill.
        static let badgeHeight: CGFloat = 24
        static let syncButtonLeadingPadding: CGFloat = 18
        static let syncButtonTrailingPadding: CGFloat = 5
        /// Status chips (with a dot) and tags (outline, no dot).
        static let chipHeight: CGFloat = 24
        static let tagHeight: CGFloat = 22
        static let chipPaddingHorizontal: CGFloat = 10
        /// The segmented pill: track inset and segment height.
        static let segmentTrackInset: CGFloat = 3
        static let segmentHeight: CGFloat = 30
        /// Pending and banner dots.
        static let bannerDotSize: CGFloat = 8
        /// Rows: tables 52, scopes 36, sidebar repositories 32.
        static let tableRowHeight: CGFloat = 52
        /// The content height of a native `Table` cell that yields a `tableRowHeight` row
        /// (`.fxTableCell()`; the inset table style adds the rest).
        static let tableCellMinHeight: CGFloat = 44
        static let scopeRowHeight: CGFloat = 36
        static let sidebarRowHeight: CGFloat = 32
        /// Avatars in the sidebar account row.
        static let avatarSize: CGFloat = 26
        /// The FractalX mark: toolbar 18, lock 44, onboarding 44, About 84.
        static let brandMarkSmall: CGFloat = 18
        static let brandMarkLarge: CGFloat = 44
        /// The dot grid behind the lock screen: one dot every 22 pt.
        static let dotGridSpacing: CGFloat = 22
        static let dotGridDotDiameter: CGFloat = 2
        /// Widest lock-screen form and onboarding text column.
        static let lockFormWidth: CGFloat = 360
        static let onboardingTextWidth: CGFloat = 460
        static let onboardingSidePanelWidth: CGFloat = 300
        /// The focus ring drawn by the design components (brand, outside the shape).
        static let focusRingWidth: CGFloat = 2
        static let focusRingOffset: CGFloat = 2

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
        static let strengthBarHeight: CGFloat = 4
        /// Recovery key grid: the 14 groups are shown on two rows (§5.3).
        static let recoveryKeyRows = 2
        static let recoveryKeyColumns = Limits.recoveryKeyGroupCount / recoveryKeyRows
        static let recoveryGroupFieldWidth: CGFloat = 88
        /// Preferences › Teammates › port field (v0.6.0).
        static let portFieldWidth: CGFloat = 88
        static let secretEditorMinHeight: CGFloat = 96

        // MARK: Main window

        static let sidebarMinWidth: CGFloat = 220
        static let sidebarIdealWidth: CGFloat = 260
        static let scopeListMinWidth: CGFloat = 200
        static let scopeListIdealWidth: CGFloat = 220
        /// The toolbar title item (mark, name, path) sits over the scope column. Sized from the
        /// default scope column so the title stays left of the scope/detail divider and the
        /// toolbar buttons after it start just right of the divider.
        static let toolbarTitleWidth: CGFloat = scopeListIdealWidth - Theme.Spacing.xLarge
        static let detailMinWidth: CGFloat = 420
        /// Detail table columns. Name and value are flexible from their minimums; the name starts
        /// at its ideal width so a long mono name ("STRIPE_SECRET_KEY") is not truncated; the value
        /// fits eight mask dots with the eye, or the "Value missing" chip. Date and status are
        /// fixed (the date fits "Oct 15 · 10:42 AM" and "Jan 1, 2001", the status the widest chip,
        /// "Will push"). Together with the cell spacing they fit the detail column of a
        /// default-size window (1120 pt) without a horizontal scroll: the ideal widths must not
        /// add up to more, or the table scrolls.
        static let tableNameMinWidth: CGFloat = 120
        static let tableNameIdealWidth: CGFloat = 144
        static let tableValueMinWidth: CGFloat = 120
        static let tableDateMinWidth: CGFloat = 128
        static let tableStatusMinWidth: CGFloat = 90
        static let statusDotSize: CGFloat = 6
        /// Width of the provider symbol in a destination row (v0.8.0), so names line up.
        static let destinationSymbolWidth: CGFloat = 16
        /// The Overview matrix (v0.8.0): the name column and each destination column.
        static let overviewNameMinWidth: CGFloat = 200
        static let overviewCellMinWidth: CGFloat = 104
        static let overviewCycleWidth: CGFloat = 76
        /// The Add Destination sheet.
        static let destinationSheetWidth: CGFloat = 520
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
        /// The scope tree gives way down to this height when the sheet is short.
        static let shareListMinHeight: CGFloat = 140
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

        // MARK: Linked copies (v0.4.1)

        /// Width of the linked copies popover and of the "Copy to Another Repository" list.
        static let linkedPopoverWidth: CGFloat = 380
        /// Tallest the linked copies list grows before it scrolls.
        static let linkedListMaxHeight: CGFloat = 280
        /// Height of the repository list in "Copy to Another Repository".
        static let copyTargetListHeight: CGFloat = 320

        // MARK: Teammates nearby (v0.5.0)

        /// Bubbles shown in the toolbar before "+N".
        static let presenceMaxBubbles = 4
        /// How much neighbouring bubbles overlap.
        static let presenceOverlap: CGFloat = 6
        /// Width of a person's popover and of the "+N" list.
        static let presencePopoverWidth: CGFloat = 300
        /// The sidebar's TEAMMATES section scrolls beyond this height (v0.7.0).
        static let sidebarTeammatesMaxHeight: CGFloat = 220
        /// The Add Teammate sheet.
        static let addTeammateSheetWidth: CGFloat = 520
        /// The people list in Add Teammate.
        static let addTeammateListHeight: CGFloat = 220
    }

    /// Opacity levels for states and tinted backgrounds.
    enum Opacity {
        /// Legacy tinted chip fill (v0.2 screens); new chips are outlined or `surface2`.
        static let chipBackground: Double = 0.15
        /// Legacy card border (v0.2 screens); new borders use `Theme.Colors.hairline`.
        static let cardBorder: Double = 0.08
        /// Disabled controls (the mockup's offline Sync pill).
        static let disabled: Double = 0.4
        /// A pressed pill.
        static let pressed: Double = 0.82
        /// A hovered ink or danger pill.
        static let hovered: Double = 0.9
    }

    /// Line widths.
    nonisolated enum Stroke {
        /// Every border and divider: 1 pt hairlines instead of shadows.
        static let hairline: CGFloat = 1
        /// The ring that separates overlapping presence bubbles (v0.5.0).
        static let emphasis: CGFloat = 2
        /// Dashed hairlines ("+ New Environment"): 4 pt dashes, 4 pt gaps.
        static let dashPattern: [CGFloat] = [4, 4]
        /// The outlined center cell of the brand mark, as a fraction of the mark's size.
        static let brandMarkCenterFraction: CGFloat = 0.03
    }

    /// The one soft shadow, for sheets drawn in the window (`Card` with `.sheet`). Everything
    /// else is flat with hairlines.
    enum Shadow {
        static let sheetRadius: CGFloat = 32
        static let sheetY: CGFloat = 24
    }
}
