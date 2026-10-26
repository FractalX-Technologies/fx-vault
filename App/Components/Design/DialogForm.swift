import SwiftUI

// The form of a 1.0 dialog (boards NewRepo, NewEnvironment, Share-Pick): a 150 pt column of
// 11 pt labels, 28 pt fields and pop-up buttons in one box (``DialogFieldChrome``), 11 pt notes
// under them (`ConfigEditorNoteView(style: .dialog)`), name chips and tags. Rows sit 14 pt apart.

/// One row: the label, 14 pt from its controls and notes. The controls carry their own
/// accessibility labels, so the column label is hidden from VoiceOver.
struct DialogFormRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.mediumPlus) {
            Text(label)
                .fxTextStyle(.formLabel)
                .foregroundStyle(Theme.Colors.mutedText)
                .frame(width: Theme.Layout.dialogLabelWidth, alignment: .leading)
                .padding(.top, Theme.Layout.dialogLabelTopInset)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Layout.dialogNoteSpacing) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A switch with its title after it ("Add README", "Clone to my Mac"); the title toggles it too,
/// unless the row is disabled.
struct DialogSwitch: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            Text(title)
                .fxTextStyle(.callout)
                .foregroundStyle(isEnabled ? Theme.Colors.ink : Theme.Colors.mutedText)
                .onTapGesture {
                    if isEnabled { isOn.toggle() }
                }
                .accessibilityHidden(true)
        }
    }
}

/// The one box of a dialog form's fields, pop-ups and shown values: 28 pt, 7 pt corners, `card`
/// with a hairline in `border` (strong at rest; ink focused, danger invalid for a text field).
/// It fades once when disabled, so a control inside must not fade again.
struct DialogFieldChrome: ViewModifier {
    var border: Color = Theme.Colors.hairlineStrong
    /// A pop-up's chevrons sit closer to the edge than a text field's last character.
    var trailingInset: CGFloat = Theme.Spacing.small
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
        content
            .padding(.leading, Theme.Spacing.mediumMinus)
            .padding(.trailing, trailingInset)
            .frame(maxWidth: .infinity, minHeight: Theme.Layout.dialogFieldHeight)
            .background(Theme.Colors.card, in: shape)
            .overlay(shape.strokeBorder(border, lineWidth: Theme.Stroke.hairline))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : Theme.Opacity.disabled)
    }
}

extension View {
    /// ``DialogFieldChrome``: a value shown without a menu, or the body of
    /// ``DialogFieldButtonStyle`` and `.fxInputField(.dialog)`.
    func dialogFieldChrome(border: Color = Theme.Colors.hairlineStrong, trailingInset: CGFloat = Theme.Spacing.small) -> some View {
        modifier(DialogFieldChrome(border: border, trailingInset: trailingInset))
    }
}

/// The field-like button of a dialog form: a 28 pt box with 7 pt corners, its title (mono for
/// names), and the pop-up chevrons unless it only shows a value. Used by ``DialogPopUp`` and by
/// buttons that open a panel (the clone folder).
struct DialogFieldButtonStyle: ButtonStyle {
    var isMonospaced = false
    var showsIndicator = true

    func makeBody(configuration: Configuration) -> some View {
        DialogFieldButtonBody(style: self, configuration: configuration)
    }
}

private struct DialogFieldButtonBody: View {
    let style: DialogFieldButtonStyle
    let configuration: ButtonStyleConfiguration

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            configuration.label
                .font(style.isMonospaced ? Theme.Typography.monoMeta : Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if style.showsIndicator {
                Image(systemName: "chevron.up.chevron.down")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .accessibilityHidden(true)
            }
        }
        .dialogFieldChrome()
        .opacity(configuration.isPressed ? Theme.Opacity.pressed : 1)
    }
}

/// A dialog form's pop-up: the field-like button showing `display` (".gitignore: None"), a menu
/// with a check beside the chosen option. VoiceOver reads the title and the chosen option.
struct DialogPopUp<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String

        var id: Value { value }
    }

    let title: String
    @Binding var selection: Value
    let options: [Option]
    var display: String?
    var isMonospaced = false

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options) { option in
                    Text(verbatim: option.title).tag(option.value)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(verbatim: display ?? selectedTitle)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(DialogFieldButtonStyle(isMonospaced: isMonospaced))
        .focusEffectDisabled()
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: selectedTitle))
    }

    private var selectedTitle: String {
        options.first { $0.value == selection }?.title ?? ""
    }
}

/// A name in a dialog form (`production ×`, `release/* · branch ×`): 22 pt, 6 pt corners, the
/// name opens it when `onSelect` is given, the cross removes it.
struct DialogTokenChip: View {
    let title: String
    let removeLabel: String
    var onSelect: (() -> Void)?
    let onRemove: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.token, style: .continuous)
        HStack(spacing: Theme.Spacing.smallMinus) {
            if let onSelect {
                Button(action: onSelect) {
                    name
                }
                .buttonStyle(.plain)
            } else {
                name
            }
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: removeLabel))
            .help(removeLabel)
        }
        .padding(.horizontal, Theme.Spacing.small)
        .frame(height: Theme.Layout.dialogChipHeight)
        .overlay(shape.stroke(Theme.Colors.hairlineStrong, lineWidth: Theme.Stroke.hairline).padding(Theme.Stroke.hairline / 2))
    }

    private var name: some View {
        Text(verbatim: title)
            .fxTextStyle(.monoMeta)
            .foregroundStyle(Theme.Colors.ink)
            .lineLimit(1)
    }
}

/// A tag beside a name in a dialog list (`production`, board Share-Pick): 18 pt, 6 pt corners,
/// an ink hairline, 11 pt medium.
struct DialogTag: View {
    let title: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.token, style: .continuous)
        Text(verbatim: title)
            .fxTextStyle(.formLabel)
            .foregroundStyle(Theme.Colors.ink)
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.smallMinus)
            .frame(height: Theme.Layout.dialogTagHeight)
            .overlay(shape.strokeBorder(Theme.Colors.ink, lineWidth: Theme.Stroke.hairline))
            .fixedSize()
    }
}

/// The dashed "+ Add" chip after a dialog form's names.
struct DialogAddChip: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DialogAddChipLabel(title: title)
        }
        .buttonStyle(.plain)
    }
}

/// The dashed chip itself, also the label of a menu that adds a name (Share-Pick's Add
/// Repository).
struct DialogAddChipLabel: View {
    let title: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.token, style: .continuous)
        Label(title, systemImage: "plus")
            .labelStyle(DialogAddChipLabelStyle())
            .padding(.horizontal, Theme.Spacing.small)
            .frame(height: Theme.Layout.dialogChipHeight)
            .overlay(
                shape.stroke(Theme.Colors.hairlineStrong, style: StrokeStyle(lineWidth: Theme.Stroke.hairline, dash: Theme.Stroke.dashPattern))
                    .padding(Theme.Stroke.hairline / 2)
            )
            .contentShape(shape)
    }
}

private struct DialogAddChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            configuration.icon
                .font(Theme.Typography.label)
            configuration.title
                .fxTextStyle(.caption)
        }
        .foregroundStyle(Theme.Colors.ink)
    }
}

#Preview("Dialog form") {
    VStack(alignment: .leading, spacing: Theme.Spacing.mediumPlus) {
        DialogFormRow("Owner") {
            DialogPopUp(
                title: "Owner",
                selection: .constant("example-org"),
                options: [.init(value: "example-org", title: "example-org"), .init(value: "owner-a", title: "owner-a")],
                isMonospaced: true
            )
        }
        DialogFormRow("Name") {
            TextField(text: .constant("billing-service")) {
                Text(verbatim: "Name")
            }
            .fxInputField(.dialog, isMonospaced: true)
            ConfigEditorNoteView(note: .info("Probably available · GitHub confirms it at Sync"), style: .dialog)
        }
        DialogFormRow("Environments to create") {
            FlowLayout(spacing: Theme.Spacing.smallMinus) {
                DialogTokenChip(title: "production", removeLabel: "Remove production") {}
                DialogTokenChip(title: "staging", removeLabel: "Remove staging") {}
                DialogAddChip(title: "Add") {}
            }
        }
        DialogFormRow("Stages") {
            DialogTag(title: "production")
        }
    }
    .padding(Theme.Layout.dialogInset)
    .frame(width: Theme.Layout.createRepoSheetWidth)
    .background(Theme.Colors.card)
}
