import SharingKit
import SwiftUI

/// A generated passphrase (D8, §9.2) as large Geist Mono words in a card, numbered so it can be
/// read out or written down, with Copy. Hidden from screen capture. Used by onboarding (the
/// generated master password) and Share as File.
struct PassphraseView: View {
    let passphrase: String
    let onCopy: () -> Void

    private var words: [String] {
        passphrase.components(separatedBy: PassphraseGenerator.separator)
    }

    /// Two columns, so the longest list words stay on one line at the large size.
    private let columns = [
        GridItem(.flexible(), spacing: Theme.Spacing.large, alignment: .leading),
        GridItem(.flexible(), spacing: Theme.Spacing.large, alignment: .leading),
    ]

    var body: some View {
        Card(spacing: Theme.Spacing.largePlus) {
            SectionLabel(String(localized: "shareExport.passphrase.title", defaultValue: "Passphrase"))
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.medium) {
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                        Text(StepCounter.padded(index + 1))
                            .fxTextStyle(.monoMeta)
                            .foregroundStyle(Theme.Colors.subtleText)
                            .accessibilityHidden(true)
                        Text(verbatim: word)
                            .fxTextStyle(.passphraseWord)
                            .foregroundStyle(Theme.Colors.ink)
                            .lineLimit(1)
                    }
                }
            }
            HStack(spacing: Theme.Spacing.medium) {
                Text(String(
                    localized: "passphrase.note",
                    defaultValue: "Write it down or save it in a password manager before you continue."
                ))
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Spacing.small)
                Button {
                    onCopy()
                } label: {
                    Label(String(localized: "passphrase.copy", defaultValue: "Copy"), systemImage: "doc.on.doc")
                }
                .fxButtonStyle(.outline)
            }
        }
        .accessibilityElement(children: .contain)
        .screenCaptureProtected()
    }
}

#Preview {
    PassphraseView(passphrase: "alpha-bravo-charlie-delta-echo-foxtrot") {}
        .padding(Theme.Spacing.xxLarge)
        .frame(width: Theme.Layout.cardWidth)
}
