import SwiftUI
import VaultCore

/// A file secret's value while masked (1.0 F1; boards Place-Table, Main2-Repository): the doc
/// symbol and "AuthKey.p8 · 6 lines" on the `surface2` token, in place of the dots. It says
/// where the value came from, never what it is.
struct FileSecretChip: View {
    let text: String
    let file: FileSecretModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.token, style: .continuous)
        HStack(spacing: Theme.Spacing.xSmall) {
            Image(systemName: "doc")
                .font(Theme.Typography.monoLabel)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .fxTextStyle(.monoLabel)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Theme.Colors.mutedText)
        .padding(.horizontal, Theme.Spacing.smallMinus)
        .frame(height: Theme.Layout.notesTokenHeight)
        .background(Theme.Colors.surface2, in: shape)
        .help(text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FileSecretCopy.accessibilityLabel(file))
    }
}

extension FileSecretChip {
    /// The table's chip: "AuthKey.p8 · 6 lines".
    static func table(_ file: FileSecretModel) -> Self {
        Self(text: FileSecretCopy.tableLabel(file), file: file)
    }

    /// The notes' chip: "AuthKey.p8 · file · 6 lines".
    static func notes(_ file: FileSecretModel) -> Self {
        Self(text: FileSecretCopy.notesLabel(file), file: file)
    }
}
