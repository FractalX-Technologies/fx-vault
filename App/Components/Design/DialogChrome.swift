import SwiftUI

// The pieces of the 1.0 dialogs (boards Sync-Review, Sync-Progress, Sync-Delete, NewRepo,
// Share-*): the quiet grey list box, the dialog sheet and its title. Cards are
// `.fxCardBackground(.dialog)`; buttons are `.dialog` size.

extension View {
    /// The grey box that lists what a confirmation is about, without a border (board
    /// Sync-Delete): `surface` with 10 pt corners, 8 pt above and below, 12 pt at the sides.
    func fxDialogListBox() -> some View {
        padding(.vertical, Theme.Spacing.small)
            .padding(.horizontal, Theme.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }
}

extension SheetHeader {
    /// The title of a 1.0 dialog: no eyebrow, 15 pt semibold, the muted subtitle 4 pt below.
    static func dialog(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: @escaping () -> Accessory) -> Self {
        Self(
            label: nil,
            title: title,
            subtitle: subtitle,
            titleStyle: .leadEmphasized,
            subtitleStyle: .callout,
            subtitleSpacing: Theme.Spacing.xSmall,
            accessory: accessory
        )
    }
}

extension SheetHeader where Accessory == EmptyView {
    static func dialog(_ title: String, subtitle: String? = nil) -> Self {
        .dialog(title, subtitle: subtitle) { EmptyView() }
    }
}

/// A 1.0 dialog (boards NewRepo, NewEnvironment, Share-*): the title, the content 14 pt apart
/// (it scrolls when the sheet is shorter), then the footer row with its note and `.dialog`
/// buttons, without a rule above it.
struct DialogSheet<Content: View, Actions: View>: View {
    let title: String
    var subtitle: String?
    /// The footer's sentence ("Created on GitHub at the next Sync.").
    var footerNote: String?
    var isWorking = false
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.mediumPlus) {
                    SheetHeader.dialog(title, subtitle: subtitle)
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Layout.dialogInset)
                .padding(.top, Theme.Layout.dialogInset)
                .padding(.bottom, Theme.Spacing.xSmall)
            }
            ConfigSheetFooter(notice: footerNote, isWorking: isWorking, inset: SheetFooterInset.dialog, actions: actions)
        }
        .fxSheetBackground()
    }
}

#Preview("Dialog chrome") {
    VStack(alignment: .leading, spacing: Theme.Spacing.mediumMinus) {
        Text(verbatim: "api-service › production")
            .fxTextStyle(.placeName)
            .padding(Theme.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fxCardBackground(.dialog)
        Text(verbatim: "STRIPE_KEY")
            .fxTextStyle(.monoMeta)
            .fxDialogListBox()
    }
    .padding(Theme.Layout.dialogInset)
    .frame(width: Theme.Layout.syncSheetWidth)
    .background(Theme.Colors.card)
}
