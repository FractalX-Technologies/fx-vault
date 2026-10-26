import XCTest

/// Preferences › Accounts lists each organization with its access (tasks/todo.md B4): the
/// scripted account has `admin:org`, owns example-org and is a member of example-labs. Then the
/// Azure group (S1b).
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

    /// The Azure group (1.0 S1b): the UI-testing `az` is signed in to one tenant, "Example", whose
    /// subscription lists kv-example-prod. Choose Vaults… adds it, and the row then counts it.
    @MainActor
    func testChooseVaultsAddsAVaultOfTheSignedInTenant() throws {
        let tenantID = "00000000-0000-0000-0000-0000000000a1"
        let app = launch()
        try onboard(app)
        app.typeKey(",", modifierFlags: .command)
        click(app.toolbars.buttons["Accounts"])

        let tenant = app.descendants(matching: .any)[AccessibilityID.Accounts.azureTenant(tenantID)]
        XCTAssertTrue(tenant.waitForExistence(timeout: timeout), "the signed-in tenant is not listed")
        XCTAssertTrue(tenant.staticTexts["Example"].exists)
        XCTAssertTrue(tenant.staticTexts["No vaults in FX Vault"].exists)
        XCTAssertTrue(app.staticTexts[AccessibilityID.Setup.command("az logout")].exists, "Sign out of Azure gives az logout")

        click(app.buttons[AccessibilityID.Accounts.azureChooseVaults(tenantID)])
        let vault = app.checkBoxes[AccessibilityID.Connect.vault("kv-example-prod")]
        XCTAssertTrue(vault.waitForExistence(timeout: timeout), "Choose Vaults… lists the tenant's vault")
        let add = app.buttons[AccessibilityID.Accounts.azureAddVaults]
        XCTAssertFalse(add.isEnabled, "nothing is checked yet")
        click(vault)
        click(add)
        XCTAssertTrue(add.waitForNonExistence(timeout: timeout), "Add Vaults closes the sheet")
        XCTAssertTrue(tenant.staticTexts["Example Production · 1 vault"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["Added 1 vault with 1 secret."].exists)
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
