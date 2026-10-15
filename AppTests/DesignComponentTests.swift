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

    @Test func buttonSizesAndEmphasis() {
        #expect(FXButtonStyle.height(for: .regular) == Theme.Layout.buttonHeightRegular)
        #expect(FXButtonStyle.height(for: .large) == Theme.Layout.buttonHeightLarge)
        #expect(FXButtonStyle.font(for: .primary, size: .large) == Theme.Typography.bodyEmphasized)
        #expect(FXButtonStyle.font(for: .secondary, size: .large) == Theme.Typography.body)
        #expect(FXButtonStyle.font(for: .outline, size: .regular) == Theme.Typography.callout)
        #expect(FXButtonStyle.hoverOpacity(for: .primary, isHovered: true) == Theme.Opacity.hovered)
        #expect(FXButtonStyle.hoverOpacity(for: .outline, isHovered: true) == 1)
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
        #expect(Banner.defaultLabel(for: .offline) == "Offline")
        #expect(Banner.defaultLabel(for: .info) == nil)
        #expect(Banner.defaultSystemImage(for: .offline) == "wifi.slash")
        #expect(Banner.defaultSystemImage(for: .info) == nil, "info shows the brand dot")
        #expect(Banner.background(for: .offline) == Theme.Colors.surface2)
        #expect(Banner.border(for: .offline) == Theme.Colors.hairlineStrong)
        #expect(Banner.background(for: .info) == Theme.Colors.card)
        #expect(Banner.background(for: .warning) == Theme.Colors.card, "brand Review link stays AA")
        #expect(Banner.border(for: .warning) == Theme.Colors.hairlineStrong)
        #expect(Banner.symbolColor(for: .offline) == Theme.Colors.warning)
        #expect(Banner.labelColor(for: .offline) == Theme.Colors.mutedText, "AA on surface2")
        #expect(Banner.labelColor(for: .info) == Theme.Colors.subtleText)
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
        #expect(Self.renders(Banner(.offline, message: "Offline"), scheme: scheme))
        #expect(Self.renders(BrandMark(size: Theme.Layout.brandMarkLarge, center: .outlined), scheme: scheme))
        #expect(Self.renders(StepCounter(current: 2, total: 5), scheme: scheme))
        #expect(Self.renders(DotGridBackground().frame(width: 88, height: 88), scheme: scheme))
        #expect(Self.renders(SyncToolbarButton(count: 3, isSyncing: false, isEnabled: true) {}, scheme: scheme))
        #expect(Self.renders(TableNameText(name: "DATABASE_URL"), scheme: scheme))
        #expect(Self.renders(SheetHeader(label: "Review before sync", title: "Sync", subtitle: "Names only.", isExperimental: true), scheme: scheme))
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

    @Test func appKitMonospacedFontIsGeistMono() {
        #expect(Theme.Typography.nsMonospaced.fontName == FontRegistry.Face.monoRegular.postScriptName)
        #expect(Theme.Typography.nsMonospaced.pointSize == Theme.Typography.Size.body)
        let fallback = FontRegistry.nsFont(.monoMedium, size: Theme.Typography.Size.caption)
        #expect(fallback.isFixedPitch)
    }

    @Test func sharedTextStylesLiveInTheTheme() {
        #expect(Theme.TextStyle.sasCode.size == Theme.Typography.Size.sasCode)
        #expect(Theme.TextStyle.sasCode.trackingEm == Theme.Typography.Tracking.label)
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
