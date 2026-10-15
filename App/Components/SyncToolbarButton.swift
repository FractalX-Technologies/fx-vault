import SwiftUI

/// The toolbar Sync button (§10 Toolbar): prominent, with the pending count **in the label**
/// ("Sync 5", monospaced digits). Disabled at 0, while locked and while a sync runs (then it
/// shows progress).
struct SyncToolbarButton: View {
    let count: Int
    let isSyncing: Bool
    let isEnabled: Bool
    /// Replaces the help text while Sync cannot run for an outside reason (offline).
    var unavailableReason: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xSmall) {
                if isSyncing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                Text(Self.title(count: count))
                    .monospacedDigit()
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!isEnabled)
        .help(unavailableReason ?? Self.help(count: count, isSyncing: isSyncing))
        .accessibilityLabel(Self.accessibilityLabel(count: count))
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
        SyncToolbarButton(count: 5, isSyncing: false, isEnabled: true) {}
        SyncToolbarButton(count: 5, isSyncing: true, isEnabled: false) {}
    }
    .padding()
}
