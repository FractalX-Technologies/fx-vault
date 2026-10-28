import XCTest

/// The Connect phase after onboarding (tasks/todo.md B11d2, B8b2, B8b3, B8c2a): the scripted account can
/// read example-org's secrets, so it is checked; Continue leads to Azure, where the scripted vault
/// is checked; Continue imports both, and the Key Vault opens from the sidebar's Azure section
/// and leaves it with Remove from FX Vault (B8c2a).
final class ConnectUITests: VaultUITestCase {
    @MainActor
    func testConnectImportsTheOrganizationAndTheKeyVaultThenOpensItFromTheSidebar() throws {
        let app = launch(vault: .none)
        try createVault(app)

        let organization = app.checkBoxes[AccessibilityID.Connect.source("org:example-org")]
        XCTAssertTrue(organization.appears(within: timeout), "example-org is not offered")
        XCTAssertEqual(organization.value as? Int, 1, "A ready organization starts checked")
        XCTAssertFalse(app.checkBoxes[AccessibilityID.Connect.source("org:example-labs")].isEnabled)
        // The whole row answers a click, not only the box and its name (1.0.3: a click on the
        // row's empty part did nothing).
        organization.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 300, dy: 0)).click()
        XCTAssertEqual(organization.value as? Int, 0, "A click on the row must uncheck the organization")
        click(organization)
        XCTAssertEqual(organization.value as? Int, 1, "A click on the box must check it again")

        click(app.buttons[AccessibilityID.Connect.toAzure])
        let vault = app.checkBoxes[AccessibilityID.Connect.vault("kv-example-prod")]
        XCTAssertTrue(vault.appears(within: timeout), "kv-example-prod is not offered")
        XCTAssertEqual(vault.value as? Int, 1, "A listed vault starts checked")

        click(app.buttons[AccessibilityID.Connect.importSelected])
        let summary = app.descendants(matching: .any)[AccessibilityID.Connect.summary]
        XCTAssertTrue(summary.appears(within: timeout), "The import never showed its summary")
        XCTAssertTrue(app.staticTexts["1 organization"].exists)
        XCTAssertTrue(app.staticTexts["1 vault"].exists, "The vault is not in the summary")

        click(app.buttons[AccessibilityID.Connect.openVault])
        let sidebar = mainSidebar(app)
        let vaultRow = sidebar.buttons[AccessibilityID.Main.keyVault("kv-example-prod")]
        XCTAssertTrue(vaultRow.appears(within: timeout), "The vault is not under Azure")
        click(vaultRow)
        let path = app.staticTexts[AccessibilityID.Main.breadcrumb]
        XCTAssertTrue(path.appears(within: timeout))
        expect(path, toEndWith: "Azure › Example Production › kv-example-prod")

        vaultRow.rightClick()
        click(app.menuItems["Remove from FX Vault…"])
        click(dialogButton("Remove Destination", in: app))
        XCTAssertTrue(vaultRow.disappears(within: timeout), "The removed vault is still in the sidebar")
    }
}
