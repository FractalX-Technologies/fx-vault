import SwiftUI

/// The toolbar panel's Sync button (§10 Toolbar; board Main2-Home): a 28 pt ink pill with the sync
/// symbol, "Sync" and the pending count in an SF Mono badge. Disabled at 0, while locked, offline
/// (40%) and while a sync runs (then it shows progress). The menu uses ``title(count:)``.
///
/// ```swift
/// SyncToolbarButton(count: viewModel.pendingChangeCount, isSyncing: viewModel.isSyncing,
///                   isEnabled: viewModel.canSync, unavailableReason: offlineHelp) { viewModel.sync() }
/// ```
struct SyncToolbarButton: View {
    let count: Int
    let isSyncing: Bool
    let isEnabled: Bool
    /// Replaces the help text while Sync cannot run for an outside reason (offline).
    var unavailableReason: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.smallMinus) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .accessibilityHidden(true)
                Text(String(localized: "toolbar.sync.title", defaultValue: "Sync"))
                badge
            }
        }
        .buttonStyle(FXButtonStyle(
            .primary,
            size: .toolbar,
            horizontalPadding: (Theme.Layout.syncButtonLeadingPadding, Self.trailingPadding(showsBadge: showsBadge))
        ))
        .focusEffectDisabled()
        .disabled(!isEnabled)
        .help(unavailableReason ?? Self.help(count: count, isSyncing: isSyncing))
        .accessibilityLabel(Self.accessibilityLabel(count: count))
    }

    private var showsBadge: Bool {
        isSyncing || count > 0
    }

    @ViewBuilder
    private var badge: some View {
        if isSyncing {
            ProgressView()
                .controlSize(.mini)
                .tint(Theme.Colors.onInk)
                .frame(minWidth: Theme.Layout.badgeHeight, minHeight: Theme.Layout.badgeHeight)
        } else if count > 0 {
            Text(count, format: .number)
                .font(Theme.Typography.monoLabel)
                .monospacedDigit()
                .padding(.horizontal, Theme.Spacing.xSmall)
                .frame(minWidth: Theme.Layout.badgeHeight, minHeight: Theme.Layout.badgeHeight)
                .background(Theme.Colors.inkBadge, in: .pill)
        }
    }

    /// The pill hugs its badge; without one it is symmetric.
    static func trailingPadding(showsBadge: Bool) -> CGFloat {
        showsBadge ? Theme.Layout.syncButtonTrailingPadding : Theme.Layout.syncButtonLeadingPadding
    }

    static func title(count: Int) -> String {
        count > 0
            ? String(localized: "toolbar.sync.titleCount", defaultValue: "Sync \(count)")
            : String(localized: "toolbar.sync.title", defaultValue: "Sync")
    }

    static func accessibilityLabel(count: Int) -> String {
        String(localized: "toolbar.sync.accessibility", defaultValue: "Sync \(count) pending changes")
    }

    static func help(count: Int, isSyncing: Bool) -> String {
        if isSyncing {
            return String(localized: "toolbar.sync.help.running", defaultValue: "A sync is running")
        }
        return count > 0
            ? String(localized: "toolbar.sync.help.pending", defaultValue: "Push \(count) pending changes to GitHub")
            : String(localized: "toolbar.sync.help.none", defaultValue: "No pending changes")
    }
}

#Preview {
    HStack {
        SyncToolbarButton(count: 0, isSyncing: false, isEnabled: false) {}
        SyncToolbarButton(count: 3, isSyncing: false, isEnabled: true) {}
        SyncToolbarButton(count: 3, isSyncing: true, isEnabled: false) {}
    }
    .padding(Theme.Spacing.xxLarge)
    .background(Theme.Colors.ground)
}
