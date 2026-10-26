import SwiftUI
import VaultCore

/// A value cell (§5.11): a masked secret with an eye toggle, a revealed secret, a variable in
/// plaintext, or the "Value missing" chip.
///
/// The cell holds no value of its own: the view model decrypts on toggle and decides when to
/// mask again (after `Timeouts.revealRemask`, on resign active, on lock), so the rules are
/// tested in one place (`RepoDetailViewModel`).
struct MaskedValueCell: View {
    let display: ConfigValueDisplayModel
    /// The file a file secret came from (1.0 F1): its chip stands in for the dots.
    var file: FileSecretModel?
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
            HStack(spacing: Theme.Spacing.mediumMinus) {
                if revealed == nil, let file {
                    FileSecretChip.table(file)
                } else {
                    valueText(revealed ?? Self.mask, isMasked: revealed == nil)
                }
                if let onToggle {
                    Button(action: onToggle) {
                        Label(
                            revealed == nil ? Self.revealTitle : Self.hideTitle,
                            systemImage: revealed == nil ? "eye" : "eye.slash"
                        )
                    }
                    .fxIconButtonStyle(.ghost)
                    .help(revealed == nil ? Self.revealTitle : Self.hideTitle)
                }
            }
        }
    }

    private var revealed: String? {
        if case .revealed(let value) = display { return value }
        return nil
    }

    /// Masked dots in the spaced mono style (`mutedText`); values in mono `ink` (mockup Main).
    private func valueText(_ text: String, isMasked: Bool) -> some View {
        Text(verbatim: text)
            .fxTextStyle(isMasked ? .monoValue : .monoName)
            .foregroundStyle(isMasked ? Theme.Colors.mutedText : Theme.Colors.ink)
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
    .padding(Theme.Spacing.large)
    .background(Theme.Colors.card)
}
