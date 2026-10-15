import SwiftUI

// The grouped-form look of the Settings tabs in the FractalX language: sections are a mono
// section label over a 16 pt hairline container whose rows are separated by hairlines, with an
// optional caption under it. Native toggles, pickers and text fields stay native inside the rows
// (docs/DESIGN.md, "Settings").

/// One Settings tab: a scrolling column of ``PreferencesSection``s on the ground.
struct PreferencesPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
                content()
            }
            .padding(Theme.Spacing.xLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.Colors.ground)
    }
}

/// A settings group: an optional ``SectionLabel``, the rows in a `.container` card (separate
/// them with `HairlineDivider()`), and an optional footnote.
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
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if let title {
                SectionLabel(title)
                    .padding(.horizontal, Theme.Spacing.xSmall)
            }
            Card(.container, spacing: 0) {
                content()
            }
            if let footnote {
                Text(footnote)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Spacing.xSmall)
            }
        }
    }
}

/// A row with the label (and an optional detail line) on the left and its control on the right.
struct PreferencesRow<Control: View>: View {
    let label: String
    var detail: String?
    var isDetailMonospaced = false
    @ViewBuilder let control: () -> Control

    init(
        _ label: String,
        detail: String? = nil,
        isDetailMonospaced: Bool = false,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.label = label
        self.detail = detail
        self.isDetailMonospaced = isDetailMonospaced
        self.control = control
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.large) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(label)
                    .fxTextStyle(.body)
                    .foregroundStyle(Theme.Colors.ink)
                if let detail {
                    Text(detail)
                        .fxTextStyle(isDetailMonospaced ? .monoMeta : .caption)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .lineLimit(isDetailMonospaced ? 1 : nil)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: !isDetailMonospaced)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .preferencesRowPadding()
    }
}

/// A free-form row (notes, command lists, button groups) with the row padding.
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

extension View {
    /// The inset of a row inside a ``PreferencesSection``.
    fileprivate func preferencesRowPadding() -> some View {
        padding(.vertical, Theme.Spacing.medium)
            .padding(.horizontal, Theme.Spacing.large)
            .frame(minHeight: Theme.Layout.inputHeight)
    }
}

#Preview {
    PreferencesPage {
        PreferencesSection("Touch ID", footnote: "FX Vault still asks for the master password after a restart.") {
            PreferencesRow("Unlock with Touch ID") {
                Toggle(isOn: .constant(true)) { Text(verbatim: "Unlock with Touch ID") }
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            HairlineDivider()
            PreferencesRow("Clone folder", detail: "/Users/me/Developer", isDetailMonospaced: true) {
                Button {} label: { Text(verbatim: "Choose…") }.fxButtonStyle(.secondary)
            }
        }
    }
    .frame(width: Theme.Layout.settingsWidth, height: Theme.Layout.settingsMinHeight)
}
