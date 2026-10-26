import SwiftUI

/// One blocked, failed, skipped or succeeded change: title (names only), the localized reason
/// and its fix button. Drawn as a row of a ``ConfigSheetList``.
struct SyncIssueRow: View {
    let issue: SyncIssueModel
    let systemImage: String
    let tint: Color
    let onFix: (SyncFixActionModel) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                Text(verbatim: issue.title)
                    .fxTextStyle(.bodyEmphasized)
                    .foregroundStyle(Theme.Colors.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !issue.reason.isEmpty {
                    Text(verbatim: issue.reason)
                        .fxTextStyle(.caption)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Spacing.small)
            if let fix = issue.fix {
                Button(SyncCopy.fixTitle(fix)) {
                    onFix(fix)
                }
                .fxButtonStyle(.outline)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A plain notice line with an icon (notes, the write limit).
struct SyncNoteRow: View {
    let text: String
    let systemImage: String
    var tint: Color = Theme.Colors.subtleText

    var body: some View {
        Label {
            Text(verbatim: text)
                .fxTextStyle(.callout)
                .foregroundStyle(Theme.Colors.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
    }
}

/// The footer of the Sync sheet (boards Sync-Review, Sync-Progress, Sync-Delete): the notice or
/// the summary's counts on the left, then exactly the buttons the view model lists, 32 pt, with
/// their default and cancel bindings (§7.5: the deletion buttons have neither).
struct SyncFooterView: View {
    let buttons: [SyncButtonModel]
    let notice: String?
    let onAction: (SyncButtonAction) -> Void

    var body: some View {
        ConfigSheetFooter(notice: notice, inset: SheetFooterInset.dialog) {
            ForEach(buttons) { model in
                Button(model.title, role: model.isDestructive ? .destructive : nil) {
                    onAction(model.action)
                }
                .fxButtonStyle(Self.variant(for: model), size: .dialog)
                .disabled(!model.isEnabled)
                .keyboardShortcut(Self.shortcut(for: model))
            }
        }
    }

    // MARK: Resolution (pure)

    /// The boards' dialog buttons: the default is the one ink pill; the destructive confirm reads
    /// red on the outline ("Delete 1"); Cancel, Back, the run's Cancel and every other choice
    /// are outlined.
    static func variant(for model: SyncButtonModel) -> FXButtonStyle.Variant {
        if model.isDestructive { return .outlineDestructive }
        if model.isDefault { return .primary }
        return .outline
    }

    static func shortcut(for model: SyncButtonModel) -> KeyboardShortcut? {
        if model.isDefault { return .defaultAction }
        if model.isCancel { return .cancelAction }
        return nil
    }
}
