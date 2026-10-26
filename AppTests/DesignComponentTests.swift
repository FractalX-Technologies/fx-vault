import AppKit
import SwiftUI
import Testing
import VaultCore
@testable import FXVault

/// v0.3.0 design components (App/Components/Design): resolution rules and render smoke tests.
@MainActor
@Suite("Design components")
struct DesignComponentTests {
    // MARK: Buttons

    @Test func buttonVariantsUseTheApprovedColors() {
        let primary = FXButtonStyle.palette(for: .primary, isHovered: false)
        #expect(primary == .init(fill: Theme.Colors.ink, foreground: Theme.Colors.onInk, border: nil))
        let secondary = FXButtonStyle.palette(for: .secondary, isHovered: false)
        #expect(secondary == .init(fill: Theme.Colors.surface2, foreground: Theme.Colors.ink, border: Theme.Colors.hairline))
        let outline = FXButtonStyle.palette(for: .outline, isHovered: false)
        #expect(outline == .init(fill: nil, foreground: Theme.Colors.ink, border: Theme.Colors.hairlineStrong))
        #expect(FXButtonStyle.palette(for: .outline, isHovered: true).fill == Theme.Colors.surface)
        #expect(FXButtonStyle.palette(for: .ghost, isHovered: false).fill == nil)
        #expect(FXButtonStyle.palette(for: .ghost, isHovered: true).fill == Theme.Colors.surface2)
        #expect(FXButtonStyle.palette(for: .destructive, isHovered: false).fill == Theme.Colors.danger)
    }

    /// The 1.0 dialogs (boards Sync-Delete, NewRepo): 32 pt, the primary a pill, the others 8 pt
    /// rounded rectangles; the deletion confirm is red on the outline.
    @Test func dialogButtonsAreTheBoardsButtons() {
        let frame = CGRect(x: 0, y: 0, width: 120, height: Theme.Layout.buttonHeightDialog)
        let pill = Capsule.pill.path(in: frame)
        let rounded = RoundedRectangle(cornerRadius: Theme.Radius.compactRow, style: .continuous).path(in: frame)
        #expect(FXButtonStyle.height(for: .dialog) == Theme.Layout.buttonHeightDialog)
        #expect(FXButtonStyle.shape(for: .dialog, variant: .primary).path(in: frame) == pill)
        #expect(FXButtonStyle.shape(for: .dialog, variant: .outline).path(in: frame) == rounded)
        #expect(FXButtonStyle.shape(for: .dialog, variant: .outlineDestructive).path(in: frame) == rounded)
        #expect(FXButtonStyle.shape(for: .regular, variant: .outline).path(in: frame) == pill)
        #expect(FXButtonStyle.font(for: .primary, size: .dialog) == Theme.Typography.bodyEmphasized)
        #expect(FXButtonStyle.font(for: .outline, size: .dialog) == Theme.Typography.callout)
        let red = FXButtonStyle.palette(for: .outlineDestructive, isHovered: false)
        #expect(red == .init(fill: nil, foreground: Theme.Colors.danger, border: Theme.Colors.hairlineStrong))
    }

    @Test func buttonSizesAndEmphasis() {
        #expect(FXButtonStyle.height(for: .regular) == Theme.Layout.buttonHeightRegular)
        #expect(FXButtonStyle.height(for: .large) == Theme.Layout.buttonHeightLarge)
        #expect(FXButtonStyle.font(for: .primary, size: .large) == Theme.Typography.bodyEmphasized)
        #expect(FXButtonStyle.font(for: .secondary, size: .large) == Theme.Typography.body)
        #expect(FXButtonStyle.font(for: .outline, size: .regular) == Theme.Typography.callout)
        #expect(FXButtonStyle.hoverOpacity(for: .primary, isHovered: true) == Theme.Opacity.hovered)
        #expect(FXButtonStyle.hoverOpacity(for: .outline, isHovered: true) == 1)
    }

    /// A place header's buttons (board Main2-Repository): 26 pt tall with 8 pt corners, where
    /// the other sizes are capsules; the ⋯ square takes the same shape.
    @Test func compactButtonsAreShortRoundedRectangles() {
        #expect(FXButtonStyle.height(for: .compact) == 26)
        #expect(FXButtonStyle.font(for: .outline, size: .compact) == Theme.Typography.caption)
        let rect = CGRect(x: 0, y: 0, width: 80, height: 26)
        let rounded = RoundedRectangle(cornerRadius: Theme.Radius.compactRow, style: .continuous).path(in: rect)
        #expect(FXButtonStyle.shape(for: .compact, variant: .outline).path(in: rect) == rounded)
        #expect(FXButtonStyle.shape(for: .regular, variant: .outline).path(in: rect) == Capsule.pill.path(in: rect))
        #expect(FXIconButtonStyle.side(for: .compact) == 26)
        #expect(FXIconButtonStyle.shape(for: .compact).path(in: rect) == rounded)
    }

    /// The toolbar panel's Sync (board Main2-Home): a 28 pt pill with 12 pt text, its badge 16 pt.
    @Test func toolbarButtonsAreSmallPills() {
        #expect(FXButtonStyle.height(for: .toolbar) == 28)
        #expect(FXButtonStyle.font(for: .primary, size: .toolbar) == Theme.Typography.captionEmphasized)
        let rect = CGRect(x: 0, y: 0, width: 80, height: 28)
        #expect(FXButtonStyle.shape(for: .toolbar, variant: .primary).path(in: rect) == Capsule.pill.path(in: rect))
        #expect(Theme.Layout.badgeHeight == 16)
        #expect(SyncToolbarButton.trailingPadding(showsBadge: true) == 6)
        #expect(SyncToolbarButton.trailingPadding(showsBadge: false) == 12)
    }

    // MARK: Chips

    @Test func syncStatusesMapToChipTones() {
        let tones = Dictionary(uniqueKeysWithValues: ConfigSyncStatus.allCases.map { ($0, $0.tone) })
        #expect(tones[.synced] == .neutral)
        #expect(tones[.modified] == .brand)
        #expect(tones[.willPush] == .brand)
        #expect(tones[.added] == .brand)
        #expect(tones[.deleted] == .danger)
        #expect(tones[.blocked] == .danger)
        #expect(tones[.unverifiedShare] == .warning)
    }

    @Test func chipFillsFollowTheMockup() {
        #expect(StatusChip.defaultFill(for: .neutral) == .filled)
        #expect(StatusChip.defaultFill(for: .brand) == .outlined)
        let synced = StatusChip.palette(tone: .neutral, fill: .filled)
        #expect(synced == .init(foreground: Theme.Colors.mutedText, background: Theme.Colors.surface2, border: nil, dot: Theme.Colors.mutedText))
        let modified = StatusChip.palette(tone: .brand, fill: .outlined)
        #expect(modified == .init(foreground: Theme.Colors.brand, background: nil, border: Theme.Colors.brand, dot: Theme.Colors.brand))
        #expect(StatusChip.palette(tone: .neutral, fill: .outlined).border == Theme.Colors.hairlineStrong)
        // The dialogs' tag: ink for `production`, quiet for a linked row's "3 places".
        #expect(StatusChip.dialogTagPalette(.ink).border == Theme.Colors.ink)
        #expect(StatusChip.dialogTagPalette(.quiet) == .init(
            foreground: Theme.Colors.mutedText,
            background: nil,
            border: Theme.Colors.hairlineStrong,
            dot: Theme.Colors.mutedText
        ))
    }

    @Test func legacyTintsMapToTones() {
        #expect(StatusChip.tone(matching: Theme.Colors.accent) == .brand)
        #expect(StatusChip.tone(matching: Theme.Colors.pending) == .brand)
        #expect(StatusChip.tone(matching: Theme.Colors.warning) == .warning)
        #expect(StatusChip.tone(matching: Theme.Colors.textSecondary) == .neutral)
        #expect(StatusChip.tone(matching: Theme.Colors.surface) == nil)
        #expect(StatusChip(title: "DEV", tint: Theme.Colors.warning).palette == StatusChip.palette(tone: .warning, fill: .outlined))
        #expect(StatusChip.tag("Private").showsDot == false)
        #expect(StatusChip.tag("Private").height == Theme.Layout.tagHeight)
    }

    // MARK: Brand mark, step counter, dot grid

    @Test func brandMarkHasEightCellsAroundAnEmptyCenter() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 300)
        let cells = BrandMark.Geometry.cells(in: rect)
        let filled = BrandMark.Geometry.filledCells(in: rect)
        let center = BrandMark.Geometry.centerCell(in: rect)
        #expect(cells.count == 9)
        #expect(filled.count == 8)
        #expect(!filled.contains(center))
        #expect(abs(center.midX - rect.midX) < 0.001 && abs(center.midY - rect.midY) < 0.001, "the center cell is centered")
        #expect(abs(cells[0].width - 86) < 0.001, "0.86 of a 1-unit pitch in a 3-unit grid")
        #expect(abs(cells[8].maxX - 300) < 0.001 && abs(cells[8].maxY - 300) < 0.001, "the mark fills its frame")
        for (index, cell) in filled.enumerated() {
            for other in filled[(index + 1)...] {
                #expect(!cell.intersects(other))
            }
        }
    }

    @Test(arguments: [(2, 5, "02 / 05"), (1, 1, "01 / 01"), (12, 12, "12 / 12")])
    func stepCounterPadsToTwoDigits(_ current: Int, _ total: Int, _ expected: String) {
        #expect(StepCounter.text(current: current, total: total) == expected)
        #expect(StepCounter.accessibilityLabel(current: current, total: total) == "Step \(current) of \(total)")
    }

    @Test func dotGridPutsOneDotInEveryTile() {
        var dots = 0
        DotGridBackground.dotsPath(in: CGRect(x: 0, y: 0, width: 44, height: 66), spacing: 22, diameter: 2).forEach { element in
            if case .move = element { dots += 1 }
        }
        #expect(dots == 2 * 3)
        #expect(DotGridBackground.dotsPath(in: .zero, spacing: 22, diameter: 2).isEmpty)
    }

    // MARK: Banner, Sync button

    @Test func bannerTonesFollowTheMockup() {
        #expect(Banner.defaultSystemImage(for: .info) == nil, "info shows the brand dot")
        #expect(Banner.background(for: .info) == Theme.Colors.card)
        #expect(Banner.background(for: .warning) == Theme.Colors.card, "brand Review link stays AA")
        #expect(Banner.border(for: .warning) == Theme.Colors.hairlineStrong)
        #expect(Banner.symbolColor(for: .warning) == Theme.Colors.warning)
    }

    @Test func syncPillHugsItsBadge() {
        #expect(SyncToolbarButton.trailingPadding(showsBadge: true) == Theme.Layout.syncButtonTrailingPadding)
        #expect(SyncToolbarButton.trailingPadding(showsBadge: false) == Theme.Layout.syncButtonLeadingPadding)
        #expect(SyncToolbarButton.title(count: 3) == "Sync 3")
    }

    // MARK: Rendering

    private static func renders(_ view: some View, scheme: ColorScheme) -> Bool {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme).padding(Theme.Spacing.small))
        renderer.scale = 1
        guard let image = renderer.nsImage else { return false }
        return image.size.width > 0 && image.size.height > 0
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func componentsRenderInBothAppearances(_ scheme: ColorScheme) {
        #expect(Self.renders(Button {} label: { Text(verbatim: "Sync") }.fxButtonStyle(.primary, size: .large), scheme: scheme))
        #expect(Self.renders(Button {} label: { Text(verbatim: "Cancel") }.fxButtonStyle(.secondary), scheme: scheme))
        #expect(Self.renders(SectionLabel("Environment"), scheme: scheme))
        #expect(Self.renders(StatusChip(status: .modified), scheme: scheme))
        #expect(Self.renders(StatusChip.tag("Private"), scheme: scheme))
        #expect(Self.renders(Card { Text(verbatim: "Card") }, scheme: scheme))
        #expect(Self.renders(FXTextField(label: "Name", text: .constant("STRIPE_SECRET_KEY"), isMonospaced: true), scheme: scheme))
        #expect(Self.renders(SegmentedPill(selection: .constant(0), segments: [.init(value: 0, title: "Secrets", count: 5)], accessibilityLabel: "Kind"), scheme: scheme))
        #expect(Self.renders(Banner(.warning, message: "Read only", label: "Experimental"), scheme: scheme))
        #expect(Self.renders(BrandMark(size: Theme.Layout.brandMarkLarge, center: .outlined), scheme: scheme))
        #expect(Self.renders(StepCounter(current: 2, total: 5), scheme: scheme))
        #expect(Self.renders(DotGridBackground().frame(width: 88, height: 88), scheme: scheme))
        #expect(Self.renders(SyncToolbarButton(count: 3, isSyncing: false, isEnabled: true) {}, scheme: scheme))
        #expect(Self.renders(TableNameText(name: "DATABASE_URL"), scheme: scheme))
        #expect(Self.renders(SheetHeader(label: "Review before sync", title: "Sync", subtitle: "Names only."), scheme: scheme))
        #expect(Self.renders(SheetCallout(systemImage: "info.circle", tint: Theme.Colors.brand, text: "Note"), scheme: scheme))
        #expect(Self.renders(FXCheckboxRow(title: "I understand", isOn: .constant(true)), scheme: scheme))
        #expect(Self.renders(InlineErrorView(error: ErrorPresentationModel(title: "Failed", message: "Try again.")), scheme: scheme))
        #expect(Self.renders(Button {} label: { Text(verbatim: "Use recovery key") }.fxLinkButtonStyle(), scheme: scheme))
        #expect(Self.renders(PassphraseView(passphrase: "alpha-bravo-charlie-delta-echo-foxtrot") {}, scheme: scheme))
    }

    // MARK: Integration additions (v0.3.0)

    /// Pills use circular ends: the SDK's default `Capsule()` is `.continuous`, whose flatter ends
    /// showed as short straight edges on buttons and chips.
    @Test func pillsHaveCircularEnds() {
        #expect(Capsule.pill.style == .circular)
        #expect(Capsule().style == .continuous, "if the SDK default changes back, .pill can go")
    }

    /// A pill never truncates its title: its width is its title's.
    @Test func pillButtonsKeepTheirTitleWidth() {
        let pill = NSHostingController(rootView: Button {} label: {
            Text(verbatim: "Delete 3 Items on GitHub")
        }.fxButtonStyle(.destructive, size: .large))
        #expect(pill.sizeThatFits(in: CGSize(width: 40, height: 100)).width > 40)
    }

    @Test func appKitMonospacedFontIsTheSystemMono() {
        let font = Theme.Typography.nsMonospaced
        #expect(font.isFixedPitch)
        #expect(font.pointSize == Theme.Typography.Size.body)
        #expect(font.fontName == NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular).fontName)
    }

    @Test func sharedTextStylesLiveInTheTheme() {
        #expect(Theme.TextStyle.passphraseWord.size == Theme.Typography.Size.title2)
        #expect(Theme.Stroke.dashPattern.count == 2)
    }

    /// The design table row is 52 pt: `.fxTableCell()` content plus the inset table's own row
    /// padding, measured on a real `NSTableView`.
    @Test func fxTableRowsAreFiftyTwoPointsTall() async throws {
        struct Row: Identifiable {
            let id: Int
            let name: String
        }
        let rows = [Row(id: 1, name: "DATABASE_URL"), Row(id: 2, name: "SENTRY_DSN")]
        let table = Table(rows) {
            TableColumn(String("Name")) { row in
                TableNameText(name: row.name).fxTableCell()
            }
        }
        .fxTable()
        .frame(width: 400, height: 300)
        let host = NSHostingView(rootView: table)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        var tableView: NSTableView?
        for _ in 0..<50 where tableView == nil || tableView?.numberOfRows == 0 {
            host.layoutSubtreeIfNeeded()
            tableView = Self.firstTableView(in: host)
            try await Task.sleep(for: .milliseconds(20))
        }
        let resolved = try #require(tableView)
        try #require(resolved.numberOfRows == rows.count)
        let height = resolved.rect(ofRow: 0).height
        #expect(abs(height - Theme.Layout.tableRowHeight) <= 1, "row height \(height)")
    }

    private static func firstTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = firstTableView(in: subview) { return table }
        }
        return nil
    }
}
