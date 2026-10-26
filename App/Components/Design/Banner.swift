import SwiftUI

/// A full-width notice in the content column (docs/DESIGN.md, "Banners"; mockup Main and
/// MainDark): 12 pt corners, hairline border, one line of text, an optional mono label and an
/// optional link-style action.
///
/// - `.info`: `card` fill with a brand dot (a Key Vault's Refresh result · Review).
/// - `.warning`: `card` fill, hairline-strong border, warning symbol (a read-only scope, the
///   recovery-key notice; brand links stay above AA on `card`).
/// - `.offline`: `surface2` fill, hairline-strong border, `wifi.slash` and the `OFFLINE` label.
/// - `.danger`: `card` fill, danger symbol, for failures that need an action.
///
/// ```swift
/// Banner(.info, message: driftText, action: .init(title: reviewTitle) { viewModel.reviewDifferences() })
/// Banner(.offline, message: ConnectivityBannerModel.offline.message)
/// ```
struct Banner: View {
    enum Tone: Sendable {
        case info
        case warning
        case offline
        case danger
    }

    struct Action {
        let title: String
        let isEnabled: Bool
        let handler: () -> Void

        init(title: String, isEnabled: Bool = true, handler: @escaping () -> Void) {
            self.title = title
            self.isEnabled = isEnabled
            self.handler = handler
        }
    }

    let tone: Tone
    let message: String
    let label: String?
    let systemImage: String?
    let action: Action?

    /// - Parameters:
    ///   - label: the mono uppercase label on the trailing side; `.offline` defaults to "Offline".
    ///   - systemImage: overrides the tone's symbol (`.info` shows a dot, not a symbol).
    init(_ tone: Tone, message: String, label: String? = nil, systemImage: String? = nil, action: Action? = nil) {
        self.tone = tone
        self.message = message
        self.label = label ?? Self.defaultLabel(for: tone)
        self.systemImage = systemImage ?? Self.defaultSystemImage(for: tone)
        self.action = action
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            leading
            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let label {
                Text(label)
                    .fxTextStyle(.sectionLabel)
                    .foregroundStyle(Self.labelColor(for: tone))
            }
            if let action {
                Button(action.title, action: action.handler)
                    .fxLinkButtonStyle(isEmphasized: true)
                    .disabled(!action.isEnabled)
            }
        }
        .padding(.vertical, Theme.Spacing.medium)
        .padding(.horizontal, Theme.Spacing.large)
        .background(Self.background(for: tone), in: shape)
        .overlay(shape.strokeBorder(Self.border(for: tone), lineWidth: Theme.Stroke.hairline))
        .accessibilityElement(children: .combine)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
    }

    @ViewBuilder
    private var leading: some View {
        if let systemImage {
            Image(systemName: systemImage)
                .foregroundStyle(Self.symbolColor(for: tone))
                .accessibilityHidden(true)
        } else {
            Circle()
                .fill(Theme.Colors.brand)
                .frame(width: Theme.Layout.bannerDotSize, height: Theme.Layout.bannerDotSize)
                .accessibilityHidden(true)
        }
    }

    // MARK: Resolution (pure)

    static func defaultLabel(for tone: Tone) -> String? {
        tone == .offline ? String(localized: "banner.offline.label", defaultValue: "Offline") : nil
    }

    static func defaultSystemImage(for tone: Tone) -> String? {
        switch tone {
        case .info: nil
        case .warning: "exclamationmark.triangle"
        case .offline: "wifi.slash"
        case .danger: "exclamationmark.octagon"
        }
    }

    static func background(for tone: Tone) -> Color {
        switch tone {
        case .info, .warning, .danger: Theme.Colors.card
        case .offline: Theme.Colors.surface2
        }
    }

    static func border(for tone: Tone) -> Color {
        switch tone {
        case .info: Theme.Colors.hairline
        case .warning, .offline, .danger: Theme.Colors.hairlineStrong
        }
    }

    /// `subtleText` is under AA on `surface2`, so the label there is `mutedText`.
    static func labelColor(for tone: Tone) -> Color {
        background(for: tone) == Theme.Colors.surface2 ? Theme.Colors.mutedText : Theme.Colors.subtleText
    }

    static func symbolColor(for tone: Tone) -> Color {
        switch tone {
        case .info: Theme.Colors.brand
        case .warning, .offline: Theme.Colors.warning
        case .danger: Theme.Colors.danger
        }
    }
}

#Preview {
    VStack(spacing: Theme.Spacing.medium) {
        Banner(.offline, message: "No internet connection. Your changes stay in the vault; sync when you're back online.")
        Banner(.info, message: "2 changes on GitHub since your last sync", action: .init(title: "Review") {})
        Banner(.warning, message: "Touch ID needs your password after a restart.")
        Banner(.danger, message: "GitHub rejected the token.", action: .init(title: "Fix") {})
    }
    .padding(Theme.Spacing.xxLarge)
    .frame(width: Theme.Layout.detailMinWidth)
    .background(Theme.Colors.ground)
}
