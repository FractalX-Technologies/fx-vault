import SwiftUI

/// A copyable shell command (`brew install gh`, `gh auth login`, scope fixes): Geist Mono,
/// selectable, in a 12 pt quiet row with a ghost Copy button.
struct CommandRow: View {
    let command: String
    let onCopy: (String) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(verbatim: command)
                .fxTextStyle(.monoName)
                .foregroundStyle(Theme.Colors.ink)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Spacing.small)
            Button {
                onCopy(command)
            } label: {
                Label(String(localized: "command.copy", defaultValue: "Copy"), systemImage: "doc.on.doc")
            }
            .fxIconButtonStyle(.ghost)
            .help(String(localized: "command.copy.help", defaultValue: "Copy the command"))
        }
        .padding(.leading, Theme.Spacing.large)
        .padding(.trailing, Theme.Spacing.xSmall)
        .padding(.vertical, Theme.Spacing.xSmall)
        .background(Theme.Colors.surface, in: shape)
        .overlay(shape.strokeBorder(Theme.Colors.hairline, lineWidth: Theme.Stroke.hairline))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
    }
}

#Preview {
    CommandRow(command: "brew install gh") { _ in }
        .padding()
}
