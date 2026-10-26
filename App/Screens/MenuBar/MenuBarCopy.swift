import Foundation

/// The menu bar item's words (board MenuBar). Counts only: never a name or a value.
enum MenuBarCopy {
    static var openApp: String {
        String(localized: "menuBar.open", defaultValue: "Open \(AppIdentity.windowTitle)")
    }

    /// "Review Sync · 4 pending…".
    static func reviewSync(count: Int) -> String {
        String(localized: "menuBar.reviewSync", defaultValue: "Review Sync · \(count) pending…")
    }

    static var lockNow: String {
        String(localized: "menuBar.lockNow", defaultValue: "Lock Now")
    }

    static var settings: String {
        String(localized: "menuBar.settings", defaultValue: "Settings…")
    }

    static var quit: String {
        String(localized: "menuBar.quit", defaultValue: "Quit \(AppIdentity.windowTitle)")
    }
}
