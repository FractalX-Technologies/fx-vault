import AppKit

/// Shows the pending-change count on the Dock icon (§10 Toolbar: the Sync count is mirrored to
/// `NSApp.dockTile.badgeLabel`).
protocol DockBadgeDisplaying: AnyObject {
    func showBadge(count: Int)
}

/// The live Dock tile.
final class DockBadgeManager: DockBadgeDisplaying {
    func showBadge(count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? count.formatted() : nil
    }
}

/// Records the badge instead of touching the Dock (previews and tests).
final class RecordedDockBadge: DockBadgeDisplaying {
    private(set) var count = 0

    func showBadge(count: Int) {
        self.count = count
    }
}
