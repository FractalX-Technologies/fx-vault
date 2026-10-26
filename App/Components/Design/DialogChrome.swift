import SwiftUI

// The pieces of the 1.0 dialogs (boards Sync-Review, Sync-Progress, Sync-Delete, NewRepo,
// Share-*): 10 pt hairline cards on the sheet and the quiet grey list box. Sheets compose them
// with ``SheetHeader`` (`.leadEmphasized` title) and the `.dialog` buttons.

extension View {
    /// A card inside a 1.0 dialog: the `card` glass with a hairline and 10 pt corners (boards
    /// Sync-Review, Sync-Progress, Share-OpenPreview).
    func fxDialogCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        return background(Theme.Colors.card, in: shape)
            .overlay(shape.strokeBorder(Theme.Colors.hairline, lineWidth: Theme.Stroke.hairline))
    }

    /// The grey box that lists what a confirmation is about, without a border (board
    /// Sync-Delete): `surface` with 10 pt corners, 8 pt above and below, 12 pt at the sides.
    func fxDialogListBox() -> some View {
        padding(.vertical, Theme.Spacing.small)
            .padding(.horizontal, Theme.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }
}

#Preview("Dialog chrome") {
    VStack(alignment: .leading, spacing: Theme.Spacing.mediumMinus) {
        Text(verbatim: "api-service › production")
            .fxTextStyle(.placeName)
            .padding(Theme.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fxDialogCard()
        Text(verbatim: "STRIPE_KEY")
            .fxTextStyle(.monoMeta)
            .fxDialogListBox()
    }
    .padding(Theme.Layout.compactSheetInset)
    .frame(width: Theme.Layout.syncSheetWidth)
    .background(Theme.Colors.card)
}
