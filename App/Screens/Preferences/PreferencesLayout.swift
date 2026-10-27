import SwiftUI

// The grouped form of the Settings tabs (boards Settings-*): groups 14 pt apart, each an
// optional 11 pt title over a 10 pt hairline card whose rows are split by hairlines, and an
// optional 11 pt footnote. Rows put a 13 pt label (and an 11 pt detail) before their `.compact`
// controls (docs/DESIGN.md, "Settings").

/// One Settings section: a scrolling column of ``PreferencesSection``s on the main window's ground.
struct PreferencesPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.mediumPlus) {
                content()
            }
            .padding(.vertical, Theme.Spacing.large)
            .padding(.horizontal, Theme.Layout.dialogInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// A settings group: an optional title, the rows in a `.dialog` card (separate them with
/// `HairlineDivider()`), and an optional footnote.
struct PreferencesSection<Content: View>: View {
    let title: String?
    var footnote: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String?, footnote: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
            if let title {
                Text(title)
                    .fxTextStyle(.groupTitle)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .padding(.horizontal, Theme.Spacing.xSmall)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fxCardBackground(.dialog)
            if let footnote {
                PreferencesFootnote(footnote)
            }
        }
    }
}

/// The 11 pt note under a group's card.
struct PreferencesFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .fxTextStyle(.formNote)
            .foregroundStyle(Theme.Colors.subtleText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Spacing.xSmall)
    }
}

/// A row with the label (and an optional detail line) on the left and its control on the right.
struct PreferencesRow<Control: View>: View {
    let label: String
    var detail: String?
    @ViewBuilder let control: () -> Control

    init(_ label: String, detail: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.label = label
        self.detail = detail
        self.control = control
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(label)
                    .fxTextStyle(.body)
                    .foregroundStyle(Theme.Colors.ink)
                if let detail {
                    Text(detail)
                        .fxTextStyle(.formNote)
                        .foregroundStyle(Theme.Colors.subtleText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .preferencesRowPadding()
    }
}

/// A free-form row (notes, command lists, an account) with the row padding.
struct PreferencesBlock<Content: View>: View {
    var spacing: CGFloat = Theme.Spacing.small
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .preferencesRowPadding()
    }
}

/// A value a row shows without a control ("30 s", the clone folder, the gh in use).
struct PreferencesValue: View {
    let text: String
    var isMonospaced = false

    var body: some View {
        Text(verbatim: text)
            .fxTextStyle(isMonospaced ? .monoMeta : .caption)
            .foregroundStyle(Theme.Colors.mutedText)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

/// A state as the Settings boards write it: its mark, then the 12 pt title ("● Ready",
/// "○ Needs admin:org", "● Expired").
struct PreferencesStatus: View {
    enum Mark: Equatable {
        /// A green dot: nothing to do.
        case fine
        /// An ink ring, ink title: it needs the user.
        case needsYou
        /// A grey dot: over, or nothing FX Vault can tell.
        case idle
    }

    let title: String
    let mark: Mark

    var body: some View {
        HStack(spacing: Theme.Spacing.smallMinus) {
            switch mark {
            case .fine: StatusDot(color: Theme.Colors.success)
            case .needsYou: RingDot()
            case .idle: StatusDot(color: Theme.Colors.hairlineStrong)
            }
            Text(title)
                .fxTextStyle(.caption)
                .foregroundStyle(titleColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var titleColor: Color {
        switch mark {
        case .fine: Theme.Colors.mutedText
        case .needsYou: Theme.Colors.ink
        case .idle: Theme.Colors.subtleText
        }
    }
}

extension View {
    /// The inset of a row inside a ``PreferencesSection``.
    fileprivate func preferencesRowPadding() -> some View {
        padding(.vertical, Theme.Layout.settingsRowInset)
            .padding(.horizontal, Theme.Spacing.medium)
    }
}

#Preview {
    PreferencesPage {
        PreferencesSection("Lock", footnote: "FX Vault always locks when your Mac sleeps.") {
            PreferencesRow("Unlock with Touch ID") {
                Toggle(isOn: .constant(true)) { Text(verbatim: "Unlock with Touch ID") }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            HairlineDivider()
            PreferencesRow("Clone folder") {
                PreferencesValue(text: "~/Code")
                Button {} label: { Text(verbatim: "Choose…") }.fxButtonStyle(.outline, size: .compact)
            }
            HairlineDivider()
            PreferencesRow("example-org") {
                PreferencesStatus(title: "Ready", mark: .fine)
            }
        }
    }
    .frame(width: Theme.Layout.settingsWidth, height: Theme.Layout.settingsMinHeight)
}
