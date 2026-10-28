import XCTest

/// The menu bar item (board MenuBar): its menu locks the vault, which leaves nothing on screen,
/// and Open FX Vault while locked is the island, not the window. The menu lists its items only, never a name.
final class MenuBarUITests: VaultUITestCase {
    /// The UI-testing build is a Debug build ("FX Vault Dev"), and its new vault has
    /// nothing pending, so Review Sync is hidden.
    private let expectedTitles = ["Quick Vault", "Open FX Vault Dev", "Lock Now", "Settings…", "Quit FX Vault Dev"]
    // A `MenuBarExtra` doesn't pass `.accessibilityIdentifier` to its menu items (Xcode 27,
    // 2026-10-26): they are found by the titles checked above.
    private let lockNowTitle = "Lock Now"

    @MainActor
    func testLockNowHidesEverythingAndOpenShowsTheIsland() throws {
        let app = launch()
        let sidebar = mainSidebar(app)

        let menu = openMenuBarMenu(app)
        XCTAssertEqual(itemTitles(of: menu), expectedTitles)
        click(menu.menuItems[lockNowTitle])
        XCTAssertTrue(sidebar.disappears(within: timeout), "The main window stayed open while locked")
        expectNoIslandAfterLock(app)

        let field = app.secureTextFields[AccessibilityID.Island.password]
        click(openMenuBarMenu(app).menuItems[openFXVaultTitle])
        XCTAssertTrue(field.appears(within: timeout), "Open FX Vault didn't bring the island")
        XCTAssertFalse(sidebar.exists, "Open FX Vault opened the window while locked")
        type(password, into: field)
        field.typeKey(.return, modifierFlags: [])
        _ = mainSidebar(app)
    }

    /// The titles of `menu`'s items, separators left out.
    @MainActor
    private func itemTitles(of menu: XCUIElement) -> [String] {
        menu.menuItems.allElementsBoundByIndex.map(\.title).filter { !$0.isEmpty }
    }
}
