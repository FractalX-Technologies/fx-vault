import SwiftUI

/// A command to run in Terminal, then Check Again (Settings › Accounts): the note, the command
/// with Copy when the steps carry it, then Check Again, which reads the accounts again.
struct CommandCheckSteps: View {
    let message: String
    /// Nil when the command is already on screen (Azure's rows): only the note and Check Again.
    var command: String?
    let checkAgainID: String
    let isChecking: Bool
    var onCopy: (String) -> Void = { _ in }
    let onCheckAgain: () async -> Void

    var body: some View {
        Text(message)
            .fxTextStyle(.formNote)
            .foregroundStyle(Theme.Colors.subtleText)
            .fixedSize(horizontal: false, vertical: true)
        if let command {
            CommandRow(command: command, onCopy: onCopy)
        }
        Button(String(localized: "settings.accounts.checkAgain", defaultValue: "Check Again")) {
            Task { await onCheckAgain() }
        }
        .fxButtonStyle(.outline, size: .compact)
        .disabled(isChecking)
        .accessibilityIdentifier(checkAgainID)
    }
}
