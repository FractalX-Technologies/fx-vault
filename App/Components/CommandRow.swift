import SwiftUI

/// A copyable shell command (`brew install gh`, `gh auth login`, scope fixes): SF Mono,
/// selectable, in a 12 pt quiet row with a ghost Copy button, or inline in a settings row.
struct CommandRow: View {
    enum Style {
        /// Its own quiet row, the command first and Copy at the trailing edge.
        case row
        /// The trailing control of a settings row (Settings › Accounts › Azure): muted mono text
        /// that truncates in the middle, then a compact Copy that turns to Copied.
        case inline
    }

    let command: String
    var style: Style = .row
    /// **Run** for an allowlisted setup command (1.0); nil keeps the row Copy-only.
    var onRun: (() -> Void)?
    var isRunning = false
    /// The command is on the clipboard: Copy says Copied.
    var isCopied = false
    let onCopy: (String) -> Void

    var body: some View {
        switch style {
        case .row:
            HStack(spacing: Theme.Spacing.small) {
                commandText
                Spacer(minLength: Theme.Spacing.small)
                if let onRun {
                    Button(String(localized: "command.run", defaultValue: "Run"), action: onRun)
                        .fxButtonStyle(.outline)
                        .disabled(isRunning)
                        .accessibilityIdentifier(AccessibilityID.Setup.run(command))
                        .help(String(localized: "command.run.help", defaultValue: "FX Vault runs only this command, here on this Mac"))
                }
                copyButton
                    .fxIconButtonStyle(.ghost)
            }
            .padding(.leading, Theme.Spacing.large)
            .padding(.trailing, Theme.Spacing.xSmall)
            .padding(.vertical, Theme.Spacing.xSmall)
            .background(Theme.Colors.surface, in: shape)
            .overlay(shape.strokeBorder(Theme.Colors.hairline, lineWidth: Theme.Stroke.hairline))
        case .inline:
            HStack(spacing: Theme.Spacing.smallMinus) {
                commandText
                copyButton
                    .fxButtonStyle(.outline, size: .compact)
                    .fixedSize()
            }
        }
    }

    private var commandText: some View {
        Text(verbatim: command)
            .fxTextStyle(style == .row ? .monoName : .monoLabel)
            .foregroundStyle(style == .row ? Theme.Colors.ink : Theme.Colors.mutedText)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
            // A long command (a tenant id) is cut in the middle; the help shows it whole.
            .help(command)
            .accessibilityIdentifier(AccessibilityID.Setup.command(command))
    }

    private var copyButton: some View {
        Button {
            onCopy(command)
        } label: {
            if isCopied {
                Label(String(localized: "command.copied", defaultValue: "Copied"), systemImage: "checkmark")
            } else {
                Label(String(localized: "command.copy", defaultValue: "Copy"), systemImage: "doc.on.doc")
            }
        }
        .help(String(localized: "command.copy.help", defaultValue: "Copy the command"))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
    }
}

#Preview {
    VStack(alignment: .leading) {
        CommandRow(command: "brew install gh") { _ in }
        CommandRow(command: "az logout", style: .inline, isCopied: true) { _ in }
    }
    .padding()
}
