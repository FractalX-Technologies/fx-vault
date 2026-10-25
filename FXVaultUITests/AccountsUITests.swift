import XCTest

/// Preferences › Accounts lists each organization with its access (tasks/todo.md B4): the
/// scripted account has `admin:org`, owns example-org and is a member of example-labs.
final class AccountsUITests: VaultUITestCase {
    @MainActor
    func testOrganizationsShowTheirAccess() throws {
        let app = launch()
        try onboard(app)
        app.typeKey(",", modifierFlags: .command)
        click(app.toolbars.buttons["Accounts"])

        XCTAssertTrue(access(of: "example-org", in: app).contains("Ready"))
        XCTAssertTrue(access(of: "example-labs", in: app).contains("Org secrets need an org admin"))
    }

    /// The text of an organization row (its login and chip), once it appears.
    @MainActor
    private func access(of organization: String, in app: XCUIApplication) -> String {
        let row = app.descendants(matching: .any)[AccessibilityID.Accounts.organization(organization)]
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "\(organization) is not listed")
        // A combined row reports its text as its value on macOS, sometimes as its label.
        let text = [(row.value as? String) ?? "", row.label].joined(separator: " ")
        return text
    }
}
