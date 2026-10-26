import SwiftUI

/// A glass strip under the toolbar panel (1.0; boards Main2-Home, Main2-Offline): a symbol, the
/// title in semibold ink with an optional " · detail" in `mutedText`, and an optional compact
/// button. The recovery-key reminder and the connectivity notice use it.
struct MainStatusStrip: View {
    let systemImage: String
    let title: String
    var detail: String?
    var action: Banner.Action?

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: systemImage)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.ink)
                .accessibilityHidden(true)
            Text(Self.text(title: title, detail: detail))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(Self.sentence(title: title, detail: detail))
            Spacer(minLength: 0)
            if let action {
                Button(action.title, action: action.handler)
                    .fxButtonStyle(.secondary, size: .compact)
                    .disabled(!action.isEnabled)
            }
        }
        .padding(.leading, Theme.Spacing.mediumPlus)
        .padding(.trailing, Theme.Spacing.smallMinus)
        .frame(height: Theme.Layout.bannerStripHeight)
        .fxGlassPanel(radius: Theme.Radius.row)
        .accessibilityElement(children: .contain)
    }

    /// The title and detail as one plain line (the tooltip of a truncated strip).
    static func sentence(title: String, detail: String?) -> String {
        [title, detail].compactMap { $0 }.joined(separator: " · ")
    }

    /// One text, so a narrow window truncates the detail before the title.
    static func text(title: String, detail: String?) -> AttributedString {
        var text = AttributedString(title)
        text.font = Theme.Typography.calloutEmphasized
        text.foregroundColor = Theme.Colors.ink
        if let detail {
            var rest = AttributedString(" · " + detail)
            rest.font = Theme.Typography.callout
            rest.foregroundColor = Theme.Colors.mutedText
            text += rest
        }
        return text
    }
}

#Preview {
    VStack(spacing: Theme.Spacing.medium) {
        MainStatusStrip(systemImage: "key", title: "Your recovery key wasn't saved", action: .init(title: "Create New Key…") {})
        MainStatusStrip(systemImage: "wifi.slash", title: "Offline", detail: "edits stay in the vault; Sync, import and drift checks wait")
    }
    .padding(Theme.Spacing.xxLarge)
    .frame(width: Theme.Layout.detailMinWidth)
    .background(Theme.Colors.ground)
}
