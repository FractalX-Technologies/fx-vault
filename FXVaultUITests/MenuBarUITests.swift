import XCTest

/// The menu bar item (board MenuBar): its menu locks the vault, and Open FX Vault while locked
/// is the island, not the window. The menu lists its items only, never a name.
final class MenuBarUITests: VaultUITestCase {
    /// The UI-testing build is a Debug build ("FX Vault Dev"), and its onboarded vault has
    /// nothing pending, so Review Sync is hidden.
    private let expectedTitles = ["Open FX Vault Dev", "Lock Now", "Settings…", "Quit FX Vault Dev"]
    // A `MenuBarExtra` doesn't pass `.accessibilityIdentifier` to its menu items (Xcode 27,
    // 2026-10-26): they are found by the titles checked above.
    private let openTitle = "Open FX Vault Dev"
    private let lockNowTitle = "Lock Now"

    @MainActor
    func testLockNowShowsTheIslandAndOpenKeepsIt() throws {
        let app = launch()
        let sidebar = try onboard(app)

        let menu = openMenuBarMenu(app)
        XCTAssertEqual(itemTitles(of: menu), expectedTitles)
        click(menu.menuItems[lockNowTitle])
        let field = app.secureTextFields[AccessibilityID.Island.password]
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "Lock Now never showed the island")
        XCTAssertTrue(sidebar.waitForNonExistence(timeout: timeout), "The main window stayed open while locked")

        click(openMenuBarMenu(app).menuItems[openTitle])
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "Open FX Vault didn't bring the island")
        XCTAssertFalse(sidebar.exists, "Open FX Vault opened the window while locked")
        type(password, into: field)
        field.typeKey(.return, modifierFlags: [])
        _ = mainSidebar(app)
    }

    /// Clicks the menu bar item and returns its open menu.
    @MainActor
    private func openMenuBarMenu(_ app: XCUIApplication) -> XCUIElement {
        let item = app.statusItems.firstMatch
        click(item)
        let menu = item.menus.firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: timeout), "The menu bar item opened no menu")
        return menu
    }

    /// The titles of `menu`'s items, separators left out.
    @MainActor
    private func itemTitles(of menu: XCUIElement) -> [String] {
        menu.menuItems.allElementsBoundByIndex.map(\.title).filter { !$0.isEmpty }
    }
}
