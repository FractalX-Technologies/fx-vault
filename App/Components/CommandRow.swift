import SwiftUI

/// A copyable shell command (`brew install gh`, `gh auth login`, scope fixes): monospaced,
/// selectable, with a Copy button.
struct CommandRow: View {
    let command: String
    let onCopy: (String) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(verbatim: command)
                .font(Theme.Typography.monospaced)
                .foregroundStyle(Theme.Colors.textPrimary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Spacing.small)
            Button {
                onCopy(command)
            } label: {
                Label(String(localized: "command.copy", defaultValue: "Copy"), systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "command.copy.help", defaultValue: "Copy the command"))
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.xSmall)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
    }
}

#Preview {
    CommandRow(command: "brew install gh") { _ in }
        .padding()
}
