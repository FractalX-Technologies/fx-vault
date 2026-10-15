import SwiftUI

/// One blocked, failed, skipped or succeeded change: title (names only), the localized reason
/// and its fix button.
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
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(verbatim: issue.title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .textSelection(.enabled)
                Text(verbatim: issue.reason)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Spacing.small)
            if let fix = issue.fix {
                Button(SyncCopy.fixTitle(fix)) {
                    onFix(fix)
                }
                .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A plain notice line with an icon (warnings, notes, the write limit).
struct SyncNoteRow: View {
    let text: String
    let systemImage: String
    var tint: Color = Theme.Colors.textSecondary

    var body: some View {
        Label {
            Text(verbatim: text)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
    }
}

/// The footer of the Sync sheet: exactly the buttons the view model lists, with their default
/// and cancel bindings (§7.5: the deletion buttons have neither).
struct SyncFooterView: View {
    let buttons: [SyncButtonModel]
    let notice: String?
    let onAction: (SyncButtonAction) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            if let notice {
                Text(verbatim: notice)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
            ForEach(buttons) { model in
                button(model)
            }
        }
        .padding(Theme.Spacing.large)
    }

    @ViewBuilder
    private func button(_ model: SyncButtonModel) -> some View {
        let button = Button(model.title, role: model.isDestructive ? .destructive : nil) {
            onAction(model.action)
        }
        .disabled(!model.isEnabled)
        .keyboardShortcut(shortcut(for: model))
        if model.isDefault {
            button.buttonStyle(.borderedProminent)
        } else {
            button
        }
    }

    private func shortcut(for model: SyncButtonModel) -> KeyboardShortcut? {
        if model.isDefault { return .defaultAction }
        if model.isCancel { return .cancelAction }
        return nil
    }
}
