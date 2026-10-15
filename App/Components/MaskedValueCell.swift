import SwiftUI

/// A value cell (§5.11): a masked secret with an eye toggle, a revealed secret, a variable in
/// plaintext, or the "Value missing" chip.
///
/// The cell holds no value of its own: the view model decrypts on toggle and decides when to
/// mask again (after `Timeouts.revealRemask`, on resign active, on lock), so the rules are
/// tested in one place (`RepoDetailViewModel`).
struct MaskedValueCell: View {
    let display: ConfigValueDisplayModel
    /// Reveals or hides the value; nil hides the eye (for example while locked).
    let onToggle: (() -> Void)?

    /// Dots in the mask. Fixed, so the mask leaks nothing about the value's length.
    private static let maskLength = 8
    /// The placeholder shown instead of a value.
    static let mask = String(repeating: "\u{2022}", count: maskLength)

    var body: some View {
        switch display {
        case .missing:
            StatusChip.valueMissing
        case .plain(let value):
            valueText(value, isMasked: false)
        case .masked, .revealed:
            HStack(spacing: Theme.Spacing.small) {
                valueText(revealed ?? Self.mask, isMasked: revealed == nil)
                Spacer(minLength: 0)
                if let onToggle {
                    Button(action: onToggle) {
                        Image(systemName: revealed == nil ? "eye" : "eye.slash")
                    }
                    .buttonStyle(.borderless)
                    .help(revealed == nil ? Self.revealTitle : Self.hideTitle)
                    .accessibilityLabel(revealed == nil ? Self.revealTitle : Self.hideTitle)
                }
            }
        }
    }

    private var revealed: String? {
        if case .revealed(let value) = display { return value }
        return nil
    }

    private func valueText(_ text: String, isMasked: Bool) -> some View {
        Text(verbatim: text)
            .font(Theme.Typography.monospaced)
            .foregroundStyle(isMasked ? Theme.Colors.textSecondary : Theme.Colors.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .textSelection(.disabled)
    }

    static var revealTitle: String {
        String(localized: "value.reveal", defaultValue: "Reveal value")
    }

    static var hideTitle: String {
        String(localized: "value.hide", defaultValue: "Hide value")
    }
}

#Preview {
    VStack(alignment: .leading) {
        MaskedValueCell(display: .masked) {}
        MaskedValueCell(display: .revealed("example-value")) {}
        MaskedValueCell(display: .plain("https://example.com"), onToggle: nil)
        MaskedValueCell(display: .missing, onToggle: nil)
    }
    .padding()
}
