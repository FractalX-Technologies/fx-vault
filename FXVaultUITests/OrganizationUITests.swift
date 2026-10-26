import XCTest

/// An organization's own secrets and variables (tasks/todo.md B5c, B6b3a): the scripted
/// example-org row offers Import, which reads them with their visibility; then they are edited
/// in the vault for the next Sync (nothing is written to GitHub here).
final class OrganizationUITests: VaultUITestCase {
    @MainActor
    func testImportingAnOrganizationListsItsItemsWithTheirVisibility() throws {
        let app = launch()
        let table = try importExampleOrganization(app)
        for text in ["NPM_TOKEN", "STRIPE_KEY", "REGION", "all repos", "selected · 3 repos", "private and internal"] {
            XCTAssertTrue(table.staticTexts[text].waitForExistence(timeout: timeout), "\(text) is not in the table")
        }
        XCTAssertFalse(app.buttons[AccessibilityID.Main.importOrganization].exists)
    }

    @MainActor
    func testAddingAVariableAndDeletingASecretWaitForTheNextSync() throws {
        let app = launch()
        let table = try importExampleOrganization(app)

        click(app.descendants(matching: .any).matching(identifier: AccessibilityID.Place.more).firstMatch)
        // By title: a SwiftUI menu item's identifier is "menuAction:" (UI logs), never the
        // button's `accessibilityIdentifier`.
        click(app.menuItems["New Variable"])
        type("zone", into: app.textFields[AccessibilityID.ItemEditor.name])
        type("eu-west-1", into: app.textViews[AccessibilityID.ItemEditor.value])
        click(app.sheets.firstMatch.buttons["Add"])
        XCTAssertTrue(table.staticTexts["ZONE"].waitForExistence(timeout: timeout), "The new variable is not in the table")
        XCTAssertTrue(table.staticTexts["Added"].waitForExistence(timeout: timeout), "The new variable is not pending")

        table.staticTexts["NPM_TOKEN"].rightClick()
        click(app.menuItems["Delete…"])
        let confirm = app.buttons[AccessibilityID.Place.deleteConfirm]
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout), "Delete… opened no sheet")
        // Neither button is the default: Return keeps the sheet and deletes nothing.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(table.staticTexts["Deleted"].waitForExistence(timeout: 2), "Return deleted NPM_TOKEN")
        XCTAssertTrue(confirm.exists, "Return closed the sheet")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(confirm.waitForNonExistence(timeout: timeout), "Esc did not close the sheet")
        XCTAssertFalse(table.staticTexts["Deleted"].exists, "Esc deleted NPM_TOKEN")

        table.staticTexts["NPM_TOKEN"].rightClick()
        click(app.menuItems["Delete…"])
        click(confirm)
        XCTAssertTrue(table.staticTexts["Deleted"].waitForExistence(timeout: timeout), "NPM_TOKEN is not pending deletion")
    }

    /// Onboards, imports example-org from its sidebar row and returns its table.
    @MainActor
    private func importExampleOrganization(_ app: XCUIApplication) throws -> XCUIElement {
        _ = try onboard(app)
        let row = app.descendants(matching: .any)[AccessibilityID.Main.organization("example-org")]
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "example-org has no organization row")
        click(row)
        click(app.buttons[AccessibilityID.Main.importOrganization])
        let table = app.descendants(matching: .any)[AccessibilityID.Main.organizationTable]
        XCTAssertTrue(table.waitForExistence(timeout: timeout), "The import never showed the table")
        return table
    }
}
