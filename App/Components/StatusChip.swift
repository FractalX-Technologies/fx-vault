import SwiftUI
import VaultCore

/// A small tinted label: sync status, "Value missing", capability (§10.4).
struct StatusChip: View {
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            Circle()
                .fill(tint)
                .frame(width: Theme.Layout.statusDotSize, height: Theme.Layout.statusDotSize)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Layout.chipHorizontalPadding)
        .padding(.vertical, Theme.Layout.chipVerticalPadding)
        .background(tint.opacity(Theme.Opacity.chipBackground), in: Capsule())
    }
}

extension StatusChip {
    init(status: ConfigSyncStatus) {
        self.init(title: status.localizedTitle, tint: status.tint)
    }

    /// The "Value missing" chip for imported secrets (§7.8).
    static var valueMissing: StatusChip {
        StatusChip(
            title: String(localized: "status.valueMissing", defaultValue: "Value missing"),
            tint: Theme.Colors.warning
        )
    }
}

extension ConfigSyncStatus {
    var localizedTitle: String {
        switch self {
        case .synced: String(localized: "status.synced", defaultValue: "Synced")
        case .added: String(localized: "status.added", defaultValue: "Added")
        case .modified: String(localized: "status.modified", defaultValue: "Modified")
        case .deleted: String(localized: "status.deleted", defaultValue: "Deleted")
        case .blocked: String(localized: "status.blocked", defaultValue: "Blocked")
        case .unverifiedShare: String(localized: "status.unverifiedShare", defaultValue: "Unverified share")
        }
    }

    var tint: Color {
        switch self {
        case .synced: Theme.Colors.success
        case .added, .modified: Theme.Colors.pending
        case .deleted, .blocked: Theme.Colors.danger
        case .unverifiedShare: Theme.Colors.warning
        }
    }
}

#Preview {
    VStack(alignment: .leading) {
        ForEach(ConfigSyncStatus.allCases, id: \.self) { StatusChip(status: $0) }
        StatusChip.valueMissing
    }
    .padding()
}
