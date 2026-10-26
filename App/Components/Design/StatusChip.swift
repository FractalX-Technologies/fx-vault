import SwiftUI
import VaultCore

/// A small pill label: sync status, "Value missing", capability, tags (§10.4; mockup Main).
///
/// Tones follow the mockup: `.neutral` is a quiet `surface2` fill with muted text ("Synced");
/// `.brand`, `.warning`, `.danger` and `.success` are outlined in their color ("Modified",
/// "Will push", "Value missing"). A tag ("Private", "Admin") is a neutral outlined chip without a
/// dot, 22 pt tall: `StatusChip.tag(_:)`; the 1.0 dialogs' tag (`production`) is
/// `StatusChip.dialogTag(_:)`.
///
/// ```swift
/// StatusChip(status: row.status)
/// StatusChip(title: "Value missing", tone: .warning)
/// StatusChip.tag(String(localized: "repo.visibility.private", defaultValue: "Private"))
/// ```
struct StatusChip: View {
    enum Tone: Hashable, Sendable {
        case neutral
        case brand
        case warning
        case danger
        case success
    }

    enum Fill: Hashable, Sendable {
        /// `surface2` background, no border.
        case filled
        /// Transparent background, 1 pt border in the tone's line color.
        case outlined
    }

    /// The resolved colors of a chip (pure, for tests).
    struct Palette: Equatable {
        let foreground: Color
        let background: Color?
        let border: Color?
        let dot: Color
    }

    let title: String
    let palette: Palette
    let showsDot: Bool
    let height: CGFloat
    /// Nil draws the pill; a radius draws a rounded tag (``dialogTag(_:)``).
    private var cornerRadius: CGFloat?
    private var font = Theme.Typography.caption
    private var horizontalPadding = Theme.Layout.chipPaddingHorizontal

    init(title: String, tone: Tone = .neutral, fill: Fill? = nil, showsDot: Bool = true) {
        self.init(
            title: title,
            palette: Self.palette(tone: tone, fill: fill ?? Self.defaultFill(for: tone)),
            showsDot: showsDot,
            height: Theme.Layout.chipHeight
        )
    }

    /// A chip in an arbitrary color (v0.2 call sites). Theme colors map to their tone; any other
    /// color is drawn outlined in that color.
    init(title: String, tint: Color) {
        if let tone = Self.tone(matching: tint) {
            self.init(title: title, tone: tone)
        } else {
            self.init(
                title: title,
                palette: Palette(foreground: tint, background: nil, border: tint, dot: tint),
                showsDot: true,
                height: Theme.Layout.chipHeight
            )
        }
    }

    private init(title: String, palette: Palette, showsDot: Bool, height: CGFloat) {
        self.title = title
        self.palette = palette
        self.showsDot = showsDot
        self.height = height
    }

    /// An outlined neutral tag without a dot ("Private", "Admin", "Experimental").
    static func tag(_ title: String) -> StatusChip {
        StatusChip(
            title: title,
            palette: Palette(foreground: Theme.Colors.ink, background: nil, border: Theme.Colors.hairlineStrong, dot: Theme.Colors.ink),
            showsDot: false,
            height: Theme.Layout.tagHeight
        )
    }

    /// The 1.0 dialogs' tag beside a name (`production`, "Not verified"; board Share-Pick): 18 pt,
    /// 6 pt corners, an ink hairline, 11 pt medium.
    static func dialogTag(_ title: String) -> StatusChip {
        var chip = StatusChip(
            title: title,
            palette: Palette(foreground: Theme.Colors.ink, background: nil, border: Theme.Colors.ink, dot: Theme.Colors.ink),
            showsDot: false,
            height: Theme.Layout.dialogTagHeight
        )
        chip.cornerRadius = Theme.Radius.token
        chip.font = Theme.Typography.labelEmphasized
        chip.horizontalPadding = Theme.Spacing.smallMinus
        return chip
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.smallMinus) {
            if showsDot {
                StatusDot(color: palette.dot)
            }
            Text(title)
                .font(font)
                .foregroundStyle(palette.foreground)
                .lineLimit(1)
        }
        .padding(.horizontal, horizontalPadding)
        .frame(height: height)
        .background {
            if let background = palette.background {
                shaped { $0.fill(background) } pill: { $0.fill(background) }
            }
        }
        .overlay {
            if let border = palette.border {
                shaped { $0.strokeBorder(border, lineWidth: Theme.Stroke.hairline) } pill: {
                    $0.strokeBorder(border, lineWidth: Theme.Stroke.hairline)
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    /// Draws the chip's shape: the rounded tag when it has a radius, else the pill.
    @ViewBuilder
    private func shaped(
        _ tag: (RoundedRectangle) -> some View,
        pill: (Capsule) -> some View
    ) -> some View {
        if let cornerRadius {
            tag(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            pill(Capsule.pill)
        }
    }

    // MARK: Resolution (pure)

    static func defaultFill(for tone: Tone) -> Fill {
        tone == .neutral ? .filled : .outlined
    }

    static func palette(tone: Tone, fill: Fill) -> Palette {
        let foreground: Color = switch tone {
        case .neutral: Theme.Colors.mutedText
        case .brand: Theme.Colors.brand
        case .warning: Theme.Colors.warning
        case .danger: Theme.Colors.danger
        case .success: Theme.Colors.success
        }
        switch fill {
        case .filled:
            return Palette(foreground: foreground, background: Theme.Colors.surface2, border: nil, dot: foreground)
        case .outlined:
            let border = tone == .neutral ? Theme.Colors.hairlineStrong : foreground
            return Palette(foreground: foreground, background: nil, border: border, dot: foreground)
        }
    }

    static func tone(matching tint: Color) -> Tone? {
        switch tint {
        case Theme.Colors.brand: .brand
        case Theme.Colors.warning: .warning
        case Theme.Colors.danger: .danger
        case Theme.Colors.success: .success
        case Theme.Colors.mutedText, Theme.Colors.subtleText, Theme.Colors.ink: .neutral
        default: nil
        }
    }
}

extension StatusChip {
    init(status: ConfigSyncStatus) {
        self.init(title: status.localizedTitle, tone: status.tone)
    }

    /// The "Value missing" chip for imported secrets (§7.8).
    static var valueMissing: StatusChip {
        StatusChip(
            title: String(localized: "status.valueMissing", defaultValue: "Value missing"),
            tone: .warning
        )
    }
}

/// A table's sync status as the boards draw it (Main2, Org-Visibility): the tone's dot and the
/// title in caption type, no chip.
struct StatusDotLabel: View {
    let status: ConfigSyncStatus

    var body: some View {
        HStack(spacing: Theme.Spacing.smallMinus) {
            StatusDot(color: status.tint)
            Text(status.localizedTitle)
                .fxTextStyle(.caption)
                .foregroundStyle(status == .synced ? Theme.Colors.mutedText : Theme.Colors.ink)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

extension ConfigSyncStatus {
    var localizedTitle: String {
        switch self {
        case .synced: String(localized: "status.synced", defaultValue: "Synced")
        case .added: String(localized: "status.added", defaultValue: "Added")
        case .modified: String(localized: "status.modified", defaultValue: "Modified")
        case .deleted: String(localized: "status.deleted", defaultValue: "Deleted")
        case .blocked: String(localized: "status.blocked", defaultValue: "Blocked")
        case .unverifiedShare: String(localized: "status.unverifiedShare", defaultValue: "Unverified share")
        case .willPush: String(localized: "status.willPush", defaultValue: "Will push")
        }
    }

    /// Synced is quiet; pending changes are brand; deletions and blocks are danger.
    var tone: StatusChip.Tone {
        switch self {
        case .synced: .neutral
        case .added, .modified, .willPush: .brand
        case .deleted, .blocked: .danger
        case .unverifiedShare: .warning
        }
    }

    var tint: Color {
        switch self {
        case .synced: Theme.Colors.success
        case .added, .modified, .willPush: Theme.Colors.brand
        case .deleted, .blocked: Theme.Colors.danger
        case .unverifiedShare: Theme.Colors.warning
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        ForEach(ConfigSyncStatus.allCases, id: \.self) { StatusChip(status: $0) }
        StatusChip.valueMissing
        StatusChip.tag("Private")
        StatusChip.dialogTag("production")
    }
    .padding(Theme.Spacing.xxLarge)
    .background(Theme.Colors.card)
}
