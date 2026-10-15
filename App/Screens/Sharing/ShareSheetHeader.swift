import SwiftUI

/// The title block of the sharing sheets, with the "Experimental" badge for nearby sharing.
struct ShareSheetHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String
    var isExperimental = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            Image(systemName: systemImage)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Colors.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                HStack(spacing: Theme.Spacing.small) {
                    Text(title)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    if isExperimental {
                        StatusChip(
                            title: String(localized: "share.nearby.experimental", defaultValue: "Experimental"),
                            tint: Theme.Colors.warning
                        )
                        .help(String(
                            localized: "share.nearby.experimental.help",
                            defaultValue: "Nearby sharing is new. If it fails, share a file instead."
                        ))
                    }
                }
                Text(subtitle)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A one-line note with an icon (hints, confirmations, warnings) in the sharing sheets.
struct ShareNoteView: View {
    let systemImage: String
    let text: String
    var tint: Color = Theme.Colors.textSecondary

    var body: some View {
        Label {
            Text(text)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }
}
