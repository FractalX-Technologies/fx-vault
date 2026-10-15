import SharingKit
import SwiftUI

/// A generated passphrase shown word by word (D8, §9.2), with a copy action.
struct PassphraseView: View {
    let passphrase: String
    let onCopy: () -> Void

    private var words: [String] {
        passphrase.components(separatedBy: PassphraseGenerator.separator)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.xSmall) {
                ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                    Text(verbatim: word)
                        .font(Theme.Typography.monospaced)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .padding(.horizontal, Theme.Spacing.small)
                        .padding(.vertical, Theme.Spacing.xSmall)
                        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
                }
            }
            HStack {
                Text(String(
                    localized: "passphrase.note",
                    defaultValue: "Write it down or save it in a password manager before you continue."
                ))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                Spacer(minLength: Theme.Spacing.small)
                Button(String(localized: "passphrase.copy", defaultValue: "Copy"), action: onCopy)
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
        .screenCaptureProtected()
    }
}

#Preview {
    PassphraseView(passphrase: "alpha-bravo-charlie-delta-echo-foxtrot") {}
        .padding()
        .frame(width: Theme.Layout.cardWidth)
}
