import XCTest

/// The Connect phase after onboarding (tasks/todo.md B11d2): the scripted account can read
/// example-org's secrets, so it is checked; Continue imports it and the summary opens the vault.
final class ConnectUITests: VaultUITestCase {
    @MainActor
    func testConnectImportsTheReadyOrganizationAndOpensTheVault() throws {
        let app = launch()
        try createVault(app)

        let organization = app.checkBoxes[AccessibilityID.Connect.source("org:example-org")]
        XCTAssertTrue(organization.waitForExistence(timeout: timeout), "example-org is not offered")
        XCTAssertEqual(organization.value as? Int, 1, "A ready organization starts checked")
        XCTAssertFalse(app.checkBoxes[AccessibilityID.Connect.source("org:example-labs")].isEnabled)

        click(app.buttons[AccessibilityID.Connect.importSelected])
        let summary = app.descendants(matching: .any)[AccessibilityID.Connect.summary]
        XCTAssertTrue(summary.waitForExistence(timeout: timeout), "The import never showed its summary")
        XCTAssertTrue(app.staticTexts["1 organization"].exists)

        click(app.buttons[AccessibilityID.Connect.openVault])
        _ = mainSidebar(app)
    }
}
