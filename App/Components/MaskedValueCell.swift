import AppKit
import SwiftUI
import VaultCore

/// A table cell that shows a value masked, reveals it on demand and masks it again (§5.11).
///
/// - The value is fetched (decrypted) only when the eye is clicked, through `reveal`.
/// - It is masked again after ``Timeouts/revealRemask``, when FX Vault stops being the active
///   app, and when the cell disappears (a lock removes every cell).
struct MaskedValueCell: View {
    let display: ConfigValueDisplayModel
    /// Decrypts the value; returns nil when it cannot be revealed (locked, failed).
    let reveal: () async -> String?

    @State private var revealedValue: String?
    @State private var remaskTask: Task<Void, Never>?

    /// Dots in the mask. Fixed, so the mask leaks nothing about the value's length.
    private static let maskLength = 8
    /// The placeholder shown instead of a value.
    static let mask = String(repeating: "\u{2022}", count: maskLength)

    var body: some View {
        switch display {
        case .missing:
            StatusChip.valueMissing
        case .masked:
            HStack(spacing: Theme.Spacing.small) {
                Text(verbatim: revealedValue ?? Self.mask)
                    .font(Theme.Typography.monospaced)
                    .foregroundStyle(revealedValue == nil ? Theme.Colors.textSecondary : Theme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.disabled)
                Spacer(minLength: 0)
                Button {
                    toggle()
                } label: {
                    Image(systemName: revealedValue == nil ? "eye" : "eye.slash")
                }
                .buttonStyle(.borderless)
                .help(revealedValue == nil ? Self.revealTitle : Self.hideTitle)
                .accessibilityLabel(revealedValue == nil ? Self.revealTitle : Self.hideTitle)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                remask()
            }
            .onDisappear {
                remask()
            }
        }
    }

    private func toggle() {
        guard revealedValue == nil else {
            remask()
            return
        }
        remaskTask?.cancel()
        remaskTask = Task {
            guard let value = await reveal(), !Task.isCancelled else { return }
            revealedValue = value
            do {
                try await Task.sleep(for: Timeouts.revealRemask)
            } catch {
                return
            }
            revealedValue = nil
        }
    }

    private func remask() {
        remaskTask?.cancel()
        remaskTask = nil
        revealedValue = nil
    }

    private static var revealTitle: String {
        String(localized: "value.reveal", defaultValue: "Reveal value")
    }

    private static var hideTitle: String {
        String(localized: "value.hide", defaultValue: "Hide value")
    }
}

#Preview {
    VStack {
        MaskedValueCell(display: .masked) { nil }
        MaskedValueCell(display: .missing) { nil }
    }
    .padding()
}
