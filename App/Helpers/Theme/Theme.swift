import CoreGraphics
import VaultCore

/// FX Vault design system. Every color, font, spacing, radius and duration used by
/// the UI comes from `Theme`; views never hardcode them.
///
/// The FractalX design language is documented in docs/DESIGN.md.
///
/// - `Theme.Colors`: semantic colors from Assets.xcassets (light and dark variants)
/// - `Theme.Typography`: SF Pro and SF Mono; `Theme.TextStyle`: font + tracking + case (`.fxTextStyle`)
/// - `Theme.Spacing`, `Theme.Radius`: layout metrics
/// - `Theme.Durations`: motion (140 ms, spring)
/// - `Theme.Layout`: window and component sizes
/// - `Theme.Opacity`, `Theme.Stroke`, `Theme.Shadow`: states, lines and the one sheet shadow
/// - `Theme.Symbols`: the SF Symbols of places (organization, person, repository, environment)
enum Theme {
    enum Layout {
        // MARK: Design components (App/Components/Design)

        /// Pill button heights: `.regular` (toolbar, inline, table headers) and `.large` (sheet
        /// footers, onboarding, lock).
        static let buttonHeightRegular: CGFloat = 34
        static let buttonHeightLarge: CGFloat = 42
        static let buttonPaddingRegular: CGFloat = 16
        static let buttonPaddingLarge: CGFloat = 22
        /// `.compact` buttons and the ⋯ square of a place header (boards Main2-Repository,
        /// Folder-View): 26 pt, 10 pt sides.
        static let buttonHeightCompact: CGFloat = 26
        static let buttonPaddingCompact: CGFloat = 10
        /// The 1.0 dialogs' buttons (boards Sync-Progress, Sync-Delete, NewRepo, Share-*): 32 pt,
        /// the primary a pill, the others 8 pt rounded rectangles.
        static let buttonHeightDialog: CGFloat = 32
        /// `.toolbar` pills in the main window's toolbar panel (board Main2-Home: Sync): 28 pt.
        static let buttonHeightToolbar: CGFloat = 28
        static let buttonPaddingToolbar: CGFloat = 12
        /// Circular icon buttons (toolbar-style New, Share, Lock).
        static let iconButtonSize: CGFloat = 32
        /// Text fields and secure fields.
        static let inputHeight: CGFloat = 44
        /// The count badge in the toolbar Sync pill (board Main2-Home: 16 pt, 12 / 6 pt sides).
        static let badgeHeight: CGFloat = 16
        static let syncButtonLeadingPadding: CGFloat = 12
        static let syncButtonTrailingPadding: CGFloat = 6
        /// Status chips (with a dot) and tags (outline, no dot).
        static let chipHeight: CGFloat = 24
        static let tagHeight: CGFloat = 22
        static let chipPaddingHorizontal: CGFloat = 10
        /// The segmented pill: track inset and segment height.
        static let segmentTrackInset: CGFloat = 3
        static let segmentHeight: CGFloat = 30
        /// The `.small` segmented control of the 1.0 dialogs (boards NewRepo, Share-Pick).
        static let segmentTrackInsetSmall: CGFloat = 2
        static let segmentHeightSmall: CGFloat = 22
        /// Pending and banner dots.
        static let bannerDotSize: CGFloat = 8
        /// Rows: tables 34 (boards Main2, Org-Visibility), scopes 36, the sidebar tree 28.
        static let tableRowHeight: CGFloat = 34
        /// The content height of a native `Table` cell that yields a `tableRowHeight` row
        /// (`.fxTableCell()`; the inset table style adds the rest).
        static let tableCellMinHeight: CGFloat = 26
        static let scopeRowHeight: CGFloat = 36
        static let sidebarRowHeight: CGFloat = 28
        /// A shortcut chip (`⌘F`, ``KeyHint``).
        static let keyHintHeight: CGFloat = 18
        /// The FractalX mark on the lock screen and in onboarding.
        static let brandMarkLarge: CGFloat = 44
        /// The dot grid behind the lock screen: one dot every 22 pt.
        static let dotGridSpacing: CGFloat = 22
        static let dotGridDotDiameter: CGFloat = 2
        /// The notch island: its width, the radius of its lower corners, and the gap under the
        /// menu bar on a screen without a notch.
        static let islandWidth: CGFloat = 340
        static let islandCornerRadius: CGFloat = 20
        static let islandMenuBarGap: CGFloat = 6
        /// The setup command output box: about eight lines before it scrolls.
        static let commandOutputMaxHeight: CGFloat = 140
        /// Widest lock-screen form and onboarding text column.
        static let lockFormWidth: CGFloat = 360
        static let onboardingTextWidth: CGFloat = 460
        /// The focus ring drawn by the design components (brand, outside the shape).
        static let focusRingWidth: CGFloat = 2
        static let focusRingOffset: CGFloat = 2

        // MARK: Windows

        static let windowMinWidth: CGFloat = 900
        static let windowMinHeight: CGFloat = 600
        static let windowDefaultWidth: CGFloat = 1_120
        static let windowDefaultHeight: CGFloat = 720
        /// The Settings window (boards Settings-*): 640 pt wide, a 520 pt window less its tabs.
        static let settingsWidth: CGFloat = 640
        static let settingsMinHeight: CGFloat = 430
        /// A Settings row's top and bottom inset (12 pt sides), and the 26 pt pop-up of a row
        /// ("Lock after inactivity · 5 min").
        static let settingsRowInset: CGFloat = 7
        static let settingsPopUpWidth: CGFloat = 96
        /// The gh path override field: a path, so wider than the board's "Automatic" pop-up.
        static let settingsPathFieldWidth: CGFloat = 200
        /// An account's first line and the lines under it (its organizations, board Settings-Accounts).
        static let settingsAccountLineHeight: CGFloat = 24
        static let settingsSublineHeight: CGFloat = 22
        static let settingsSymbolWidth: CGFloat = 14
        /// The lines under a sent file line up with its name, past the 13 pt icon (board Settings-Sharing).
        static let settingsNamesIndent: CGFloat = 22
        /// The Reset vault dialog (board Reset-Confirm).
        static let resetDialogWidth: CGFloat = 380
        static let sheetWidth: CGFloat = 440
        /// The inset of the 1.0 dialogs (boards Sync-Progress, Sync-Delete, NewRepo, Share-*).
        static let dialogInset: CGFloat = 22
        /// A row of a dialog's grey list box (board Sync-Delete).
        static let dialogListRowHeight: CGFloat = 24
        /// A 1.0 dialog form (boards NewRepo, NewEnvironment): a 150 pt label column, 28 pt
        /// fields and pop-ups, the label 7 pt down (centred on a field), notes 5 pt under it.
        static let dialogLabelWidth: CGFloat = 150
        static let dialogFieldHeight: CGFloat = 28
        static let dialogLabelTopInset: CGFloat = 7
        static let dialogNoteSpacing: CGFloat = 5
        /// The name chips of a dialog form ("production ×") and their remove cross.
        static let dialogChipHeight: CGFloat = 22
        /// A tag beside a name in a dialog list ("production", board Share-Pick).
        static let dialogTagHeight: CGFloat = 18

        // MARK: Onboarding, lock and recovery

        /// Width of the centered card used by onboarding, lock and recovery screens.
        static let cardWidth: CGFloat = 520
        static let strengthBarHeight: CGFloat = 4
        /// Recovery key grid: the 14 groups are shown on two rows (§5.3).
        static let recoveryKeyRows = 2
        static let recoveryKeyColumns = Limits.recoveryKeyGroupCount / recoveryKeyRows
        static let recoveryGroupFieldWidth: CGFloat = 88
        static let secretEditorMinHeight: CGFloat = 96

        // MARK: Main window

        /// The sidebar panel holds the whole tree (1.0): owner › repository › environment. Its
        /// trailing gutter resizes it between the min and max widths (`PreferencesManager`).
        static let sidebarWidth: CGFloat = 264
        static let sidebarMinWidth: CGFloat = 240
        static let sidebarMaxWidth: CGFloat = 400
        /// The window chrome (1.0 D6c2b; board Main2-Home): the panels sit this far from the
        /// window's edges and from each other.
        static let mainPanelInset: CGFloat = 8
        /// The sidebar panel's content starts under the traffic lights.
        static let sidebarPanelTopInset: CGFloat = 44
        static let toolbarPanelHeight: CGFloat = 44
        /// The traffic lights from the window's leading edge (AppKit puts them 19 pt in): the
        /// toolbar panel starts after them while the sidebar is hidden.
        static let trafficLightsWidth: CGFloat = 80
        /// The recovery-key strip under the toolbar panel.
        static let bannerStripHeight: CGFloat = 36
        /// How far each corner's glow reaches into the main window's ground.
        static let groundGlowRadius: CGFloat = 720
        /// One level of the sidebar tree: owner › repository › environment (board Main2-Expanded).
        static let sidebarTreeIndent: CGFloat = 14
        /// The disclosure chevron's column and the symbol's, so names line up at every level.
        static let sidebarChevronWidth: CGFloat = 10
        static let sidebarSymbolWidth: CGFloat = 14
        /// The subline under a node ("Needs admin:org · Approve").
        static let sidebarSublineHeight: CGFloat = 18
        /// "GitHub", "Azure", "Folders"; also the size of a header's + button.
        static let sidebarSectionHeaderHeight: CGFloat = 22
        /// The search field at the top of the sidebar and the footer's icon buttons.
        static let sidebarControlHeight: CGFloat = 28
        static let detailMinWidth: CGFloat = 420
        /// The main screen's minimum: the widest sidebar beside the narrowest detail, sidebar
        /// hidden too. `windowMinWidth` (900) covers it today; this keeps MainScreen right on its
        /// own (tests, previews, a smaller window minimum later).
        static let mainScreenMinWidth = 3 * mainPanelInset + sidebarMaxWidth + detailMinWidth
        /// The ⌘K jump palette (board Main2-Search).
        static let jumpPaletteWidth: CGFloat = 600
        static let jumpPaletteFieldHeight: CGFloat = 48
        static let jumpPaletteRowHeight: CGFloat = 34
        static let jumpPaletteListMaxHeight: CGFloat = 340
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
        /// ``RingDot``: a place changed on GitHub (board Main2-Repository), a Sync line waiting or
        /// pending (boards Sync-Progress, Sync-Done).
        static let changedDotSize: CGFloat = 7
        /// Width of the provider symbol in a destination row (v0.8.0), so names line up.
        static let destinationSymbolWidth: CGFloat = 16
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
        /// Boards NewRepo (620) and NewEnvironment (580).
        static let createRepoSheetWidth: CGFloat = 620
        static let newEnvironmentSheetWidth: CGFloat = 580
        static let createRepoSheetHeight: CGFloat = 640
        /// Height of the loading and failure states.
        static let createRepoStatusHeight: CGFloat = 320
        /// Width of the nested item and environment editors.
        static let createRepoEditorWidth: CGFloat = 480

        // MARK: Sync sheet

        /// Boards Sync-Review and Sync-Progress.
        static let syncSheetWidth: CGFloat = 600
        /// The `+ ~ − !` column of the Sync summary lines (board Sync-Review).
        static let syncSymbolWidth: CGFloat = 14
        static let syncSheetMinHeight: CGFloat = 360
        static let syncSheetIdealHeight: CGFloat = 520
        /// The run's bar, full width (board Sync-Progress).
        static let syncProgressHeight: CGFloat = 4
        /// The finished run when everything ran (board Sync-Done): 420 pt, a 44 pt check ring.
        static let syncDoneWidth: CGFloat = 420
        static let syncDoneMarkSize: CGFloat = 44

        // MARK: Drift review sheet

        static let driftSheetWidth: CGFloat = 600
        static let driftSheetMinHeight: CGFloat = 360
        static let driftSheetIdealHeight: CGFloat = 480

        // MARK: .env import and export sheets

        /// The import sheet holds a five-column table.
        static let envImportSheetWidth: CGFloat = 760
        static let envImportSheetHeight: CGFloat = 560
        /// The export dialog (board Main2-Export).
        static let envExportSheetWidth: CGFloat = 580
        /// Height of the paste editor above the live preview.
        static let envPasteEditorHeight: CGFloat = 150
        /// The paste mode shows the editor above the live preview, so the sheet is taller.
        static let envImportPasteSheetHeight: CGFloat = 660
        /// Height of the parse issue list under the import table.
        static let envIssueListMaxHeight: CGFloat = 96
        /// A dialog's list of names scrolls past this (the export's "Skipped: …", the "Delete?" list).
        static let dialogListMaxHeight: CGFloat = 88
        /// The names under a dialog note line up with its sentence, past the 13 pt symbol.
        static let dialogNoteIndent: CGFloat = 21
        static let envImportIncludeColumnWidth: CGFloat = 28
        static let envImportLineColumnWidth: CGFloat = 40
        static let envImportKeyColumnMinWidth: CGFloat = 220
        static let envImportKindColumnWidth: CGFloat = 130
        static let envImportConflictColumnWidth: CGFloat = 130

        // MARK: Sharing sheets

        /// Width of the sharing steps without a board (a one-repository import, a folder copy,
        /// what an import changed).
        static let shareSheetWidth: CGFloat = 560
        /// The share dialogs (boards Share-Pick, Share-Passphrase, Share-Open, Share-OpenPreview,
        /// Share-Expired).
        static let sharePickWidth: CGFloat = 600
        static let sharePassphraseWidth: CGFloat = 680
        static let shareOpenWidth: CGFloat = 440
        static let shareOpenPreviewWidth: CGFloat = 620
        static let shareExpiredWidth: CGFloat = 360
        /// Copy All's dialog (1.0 D6c4, no board): Share-Pick's password row beside its label.
        static let copyAllSheetWidth: CGFloat = 520
        /// The tallest a share dialog grows before its content scrolls.
        static let shareSheetMaxHeight: CGFloat = 640
        /// Height of the share tree and of the one-repository import preview.
        static let shareListHeight: CGFloat = 260
        /// The import preview inside a project share's preview.
        static let shareListMinHeight: CGFloat = 140
        /// The share tree (board Share-Pick): 28 pt rows, 18 pt a level, a 10 pt chevron column.
        static let shareTreeRowHeight: CGFloat = 28
        static let shareTreeIndent: CGFloat = 18
        static let shareTreeChevronWidth: CGFloat = 10
        /// A row of what a file adds (board Share-OpenPreview).
        static let shareOpenRowHeight: CGFloat = 32
        /// The symbol over a file that cannot be opened (board Share-Expired).
        static let shareRefusedSymbolSize: CGFloat = 26
        /// Width of the per-item action picker in the import preview.
        static let shareActionPickerWidth: CGFloat = 150

        // MARK: Linked copies (v0.4.1)

        /// Width of the linked copies popover and of the "Copy to Another Repository" list.
        static let linkedPopoverWidth: CGFloat = 380
        /// Tallest the linked copies list grows before it scrolls.
        static let linkedListMaxHeight: CGFloat = 280
        /// A linked copy that can't be updated has no checkbox; its path still lines up (board
        /// Folder-LinkedUpdate: 12 pt inset, the 14 pt box, 10 pt gap).
        static let linkedUpdateBlockedInset: CGFloat = 36
        /// Height of the repository list in "Copy to Another Repository".
        static let copyTargetListHeight: CGFloat = 320
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
        /// The stroke of every ``RingDot`` (boards Main2-Repository, Sync-Progress, Sync-Done).
        static let changedDot: CGFloat = 1.5
        /// Dashed hairlines ("+ New Environment"): 4 pt dashes, 4 pt gaps.
        static let dashPattern: [CGFloat] = [4, 4]
        /// The outlined center cell of the brand mark, as a fraction of the mark's size.
        static let brandMarkCenterFraction: CGFloat = 0.03
    }

    /// The soft shadows: sheets drawn in the window (`Card` with `.sheet`) and the main window's
    /// glass panels. Everything else is flat with hairlines.
    enum Shadow {
        static let sheetRadius: CGFloat = 32
        static let sheetY: CGFloat = 24
        /// The main window's glass panels (board Main2-Home: CSS `0 8px 24px`; a SwiftUI shadow
        /// radius is half the CSS blur).
        static let panelRadius: CGFloat = 12
        static let panelY: CGFloat = 8
    }

    /// SF Symbols of the places, so the sidebar, the ⌘K palette and the Sync summary draw a
    /// place the same way (boards Main2, Main2-Search, Sync-Review). A Key Vault's is its
    /// provider's.
    enum Symbols {
        static let organization = "building.2"
        static let person = "person"
        static let repository = "book.closed"
        static let environment = "smallcircle.filled.circle"
        static let folder = "folder"
        static let folderSelected = "folder.fill"
        /// An Azure subscription in the sidebar (board Main2-Repository).
        static let subscription = "cloud"
    }
}
