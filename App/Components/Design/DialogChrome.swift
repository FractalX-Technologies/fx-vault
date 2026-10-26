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

/// The bordered box of a dialog's warnings (board Main2-Export): a hairline with 10 pt corners
/// and no fill, its ``DialogNote`` rows 8 pt apart.
struct DialogNoteBox<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            content()
        }
        .padding(.vertical, Theme.Spacing.mediumMinus)
        .padding(.horizontal, Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .strokeBorder(Theme.Colors.hairline, lineWidth: Theme.Stroke.hairline)
        )
    }
}

/// One warning of a ``DialogNoteBox``: a 13 pt symbol (ink unless `tint` says otherwise), the
/// 12 pt sentence, and an optional action at its end ("Add to .gitignore").
struct DialogNote<Accessory: View>: View {
    let systemImage: String
    let text: String
    var tint: Color = Theme.Colors.ink
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.small) {
            Image(systemName: systemImage)
                .font(Theme.Typography.body)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            accessory()
        }
    }
}

extension DialogNote where Accessory == EmptyView {
    init(systemImage: String, text: String, tint: Color = Theme.Colors.ink) {
        self.init(systemImage: systemImage, text: text, tint: tint) { EmptyView() }
    }
}

/// A dialog's body sentence (boards Main2-Export, Main2-Delete, Sync-Delete): 13 pt
/// `mutedText`, wrapped.
struct DialogSentence: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(verbatim: text)
            .fxTextStyle(.callout)
            .foregroundStyle(Theme.Colors.mutedText)
            .fixedSize(horizontal: false, vertical: true)
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
