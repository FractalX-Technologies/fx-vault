import XCTest

/// An organization's own secrets and variables (tasks/todo.md B5c): the scripted example-org
/// row offers Import, which reads them read-only with their visibility.
final class OrganizationUITests: VaultUITestCase {
    @MainActor
    func testImportingAnOrganizationListsItsItemsWithTheirVisibility() throws {
        let app = launch()
        _ = try onboard(app)
        let row = app.descendants(matching: .any)[AccessibilityID.Main.organization("example-org")]
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "example-org has no organization row")
        click(row)
        click(app.buttons[AccessibilityID.Main.importOrganization])

        let table = app.descendants(matching: .any)[AccessibilityID.Main.organizationTable]
        XCTAssertTrue(table.waitForExistence(timeout: timeout), "The import never showed the table")
        for text in ["NPM_TOKEN", "STRIPE_KEY", "REGION", "All repositories", "Selected · 3 repositories", "Private and internal repositories"] {
            XCTAssertTrue(table.staticTexts[text].waitForExistence(timeout: timeout), "\(text) is not in the table")
        }
        XCTAssertFalse(app.buttons[AccessibilityID.Main.importOrganization].exists)
    }
}
