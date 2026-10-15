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

/// The footer of the Sync sheet (board SyncReview): mono meta (the write limit) or the notice on
/// the left, then exactly the buttons the view model lists as pills, with their default and
/// cancel bindings (§7.5: the deletion buttons have neither).
struct SyncFooterView: View {
    let buttons: [SyncButtonModel]
    let notice: String?
    var meta: String?
    let onAction: (SyncButtonAction) -> Void

    var body: some View {
        ConfigSheetFooter(meta: meta, notice: notice, metaHelp: SyncCopy.writeBudgetHelp) {
            ForEach(buttons) { model in
                Button(model.title, role: model.isDestructive ? .destructive : nil) {
                    onAction(model.action)
                }
                .fxButtonStyle(Self.variant(for: model), size: .large)
                .disabled(!model.isEnabled)
                .keyboardShortcut(Self.shortcut(for: model))
            }
        }
    }

    // MARK: Resolution (pure)

    /// Destructive confirm → `.destructive`; the default → `.primary` (one per step); Cancel,
    /// Back and the run's Cancel → `.secondary`; any other choice → `.outline`.
    static func variant(for model: SyncButtonModel) -> FXButtonStyle.Variant {
        if model.isDestructive { return .destructive }
        if model.isDefault { return .primary }
        if model.isCancel || model.action == .cancelRun { return .secondary }
        return .outline
    }

    static func shortcut(for model: SyncButtonModel) -> KeyboardShortcut? {
        if model.isDefault { return .defaultAction }
        if model.isCancel { return .cancelAction }
        return nil
    }
}
