import XCTest

/// The menu bar item (board MenuBar): its menu locks the vault, and Open FX Vault while locked
/// is the island, not the window. The menu never shows a name.
final class MenuBarUITests: VaultUITestCase {
    @MainActor
    func testLockNowShowsTheIslandAndOpenKeepsIt() throws {
        let app = launch()
        let sidebar = try onboard(app)

        click(menuBarItem(AccessibilityID.MenuBar.lockNow, title: "Lock Now", in: app))
        let field = app.secureTextFields[AccessibilityID.Island.password]
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "Lock Now never showed the island")
        XCTAssertTrue(sidebar.waitForNonExistence(timeout: timeout), "The main window stayed open while locked")

        let open = menuBarItem(AccessibilityID.MenuBar.open, title: "Open FX Vault", in: app)
        XCTAssertFalse(app.menuItems["api-service"].exists, "The menu shows a name")
        click(open)
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "Open FX Vault didn't bring the island")
        XCTAssertFalse(sidebar.exists, "Open FX Vault opened the window while locked")
        type(password, into: field)
        field.typeKey(.return, modifierFlags: [])
        _ = mainSidebar(app)
    }

    /// Opens the menu bar item's menu and returns one of its items. SwiftUI may not hand the
    /// identifier to the NSMenuItem, so the title (a Debug build's name ends in "Dev") also matches.
    @MainActor
    private func menuBarItem(_ identifier: String, title: String, in app: XCUIApplication) -> XCUIElement {
        click(app.statusItems.firstMatch)
        let item = app.menuItems.matching(NSPredicate(
            format: "identifier == %@ OR title BEGINSWITH %@", identifier, title
        )).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: timeout), "The menu bar item has no \(title)")
        return item
    }
}
