import XCTest

/// The quick vault from the notch (tasks/todo.md Q1; boards QuickVault-*): the menu bar's Quick
/// Vault opens it, ↩ shows a place's lines, a variable copies, ⌘↩ opens the place in the main
/// window; while locked, the island's password opens it after the unlock. The UITesting build
/// registers no global shortcut (it must not take ⌃⌥V from the developer): the menu stands in.
final class QuickVaultUITests: VaultUITestCase {
    private let quickVaultTitle = "Quick Vault"
    private let lockNowTitle = "Lock Now"

    @MainActor
    func testTheMenuOpensItAndAPlaceCopiesAndExpands() throws {
        let app = launch()
        let sidebar = try onboard(app)
        revealRepositories(of: "example-org", in: sidebar)
        click(sidebarRow("api-service", in: sidebar))
        click(app.buttons[AccessibilityID.Main.importRepository])
        XCTAssertTrue(sidebar.buttons[AccessibilityID.Main.environment("staging")].waitForExistence(timeout: timeout))

        let field = openQuickVault(app)
        app.typeText("staging")
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "staging"), object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [typed], timeout: timeout), .completed, "The quick vault's field did not take the typing")
        field.typeKey(.return, modifierFlags: [])

        // staging's MODE variable copies at once (a secret would ask first).
        let copy = app.buttons.matching(NSPredicate(format: "label == %@", "Copy MODE")).firstMatch
        click(copy)
        let copied = app.buttons.matching(NSPredicate(format: "label == %@", "Copied MODE")).firstMatch
        XCTAssertTrue(copied.waitForExistence(timeout: timeout), "Copy did not say Copied")

        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(field.waitForNonExistence(timeout: timeout), "⌘↩ did not close the quick vault")
        expect(app.staticTexts[AccessibilityID.Main.breadcrumb], toEndWith: "api-service › staging")
    }

    @MainActor
    func testWhileLockedTheIslandUnlocksIntoIt() throws {
        let app = launch()
        _ = try onboard(app)
        click(openMenuBarMenu(app).menuItems[lockNowTitle])
        expectNoIslandAfterLock(app)
        let password = app.secureTextFields[AccessibilityID.Island.password]

        click(openMenuBarMenu(app).menuItems[quickVaultTitle])
        XCTAssertTrue(password.waitForExistence(timeout: timeout), "Quick Vault while locked didn't ask for the password")
        XCTAssertFalse(app.textFields[AccessibilityID.QuickVault.field].exists, "The quick vault opened while locked")
        type(self.password, into: password)
        password.typeKey(.return, modifierFlags: [])

        let field = app.textFields[AccessibilityID.QuickVault.field]
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "The unlock didn't open the quick vault")
        XCTAssertFalse(app.descendants(matching: .any)[AccessibilityID.Main.sidebar].exists, "The unlock opened the window too")
        field.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: timeout), "esc did not close the quick vault")
    }

    /// The menu bar's Quick Vault; returns its search field.
    @MainActor
    private func openQuickVault(_ app: XCUIApplication) -> XCUIElement {
        click(openMenuBarMenu(app).menuItems[quickVaultTitle])
        let field = app.textFields[AccessibilityID.QuickVault.field]
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "Quick Vault did not open")
        return field
    }
}
