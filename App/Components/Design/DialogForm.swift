import SwiftUI

// The form of a 1.0 dialog (boards NewRepo, NewEnvironment): a 150 pt column of 11 pt labels,
// 28 pt fields (`.fxInputField(.dialog)`) and pop-up buttons, 11 pt notes under them, and name
// chips. Sheets put the rows 14 pt apart between a `.leadEmphasized` title and the footer.

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

/// An 11 pt note under a control: muted, or red when it blocks the primary action.
struct DialogFormNote: View {
    enum Tone: Sendable {
        case muted
        case warning
        case danger
    }

    let text: String
    var tone: Tone = .muted

    init(_ text: String, tone: Tone = .muted) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(verbatim: text)
            .fxTextStyle(.formNote)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var color: Color {
        switch tone {
        case .muted: Theme.Colors.mutedText
        case .warning: Theme.Colors.warning
        case .danger: Theme.Colors.danger
        }
    }
}

extension ConfigEditorNoteModel {
    /// The tone of the same note under a dialog form's control.
    var dialogTone: DialogFormNote.Tone {
        switch tone {
        case .error: .danger
        case .warning: .warning
        case .info, .success: .muted
        }
    }
}

/// A switch with its title after it ("Add README", "Clone to my Mac"); the title toggles it too.
struct DialogSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            Text(title)
                .fxTextStyle(.callout)
                .foregroundStyle(Theme.Colors.ink)
                .onTapGesture { isOn.toggle() }
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// The box of a dialog form's field-like control: 28 pt, 7 pt corners, `card` with a strong
    /// hairline (``DialogFieldButtonStyle``, a value shown without a menu).
    func dialogFieldChrome() -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
        return padding(.leading, Theme.Spacing.mediumMinus)
            .padding(.trailing, Theme.Spacing.small)
            .frame(height: Theme.Layout.dialogFieldHeight)
            .frame(maxWidth: .infinity)
            .background(Theme.Colors.card, in: shape)
            .overlay(shape.stroke(Theme.Colors.hairlineStrong, lineWidth: Theme.Stroke.hairline).padding(Theme.Stroke.hairline / 2))
            .contentShape(shape)
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
    @Environment(\.isEnabled) private var isEnabled

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
        .opacity(isEnabled ? 1 : Theme.Opacity.disabled)
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

/// The dashed "+ Add" chip after a dialog form's names.
struct DialogAddChip: View {
    let title: String
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.token, style: .continuous)
        Button(action: action) {
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
        .buttonStyle(.plain)
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
            TextField("Name", text: .constant("billing-service"))
                .fxInputField(.dialog, isMonospaced: true)
            DialogFormNote("Probably available · GitHub confirms it at Sync")
        }
        DialogFormRow("Environments to create") {
            FlowLayout(spacing: Theme.Spacing.smallMinus) {
                DialogTokenChip(title: "production", removeLabel: "Remove production") {}
                DialogTokenChip(title: "staging", removeLabel: "Remove staging") {}
                DialogAddChip(title: "Add") {}
            }
        }
    }
    .padding(Theme.Layout.compactSheetInset)
    .frame(width: Theme.Layout.createRepoSheetWidth)
    .background(Theme.Colors.card)
}
