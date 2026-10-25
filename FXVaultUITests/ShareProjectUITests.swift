import XCTest

/// Share Project with production (tasks/todo.md B3b): the stage is unchecked by default, checking
/// it is confirmed (the ad-hoc UITesting build has no Touch ID, so the master password confirms
/// it at Create), and the file is made with its passphrase. Nothing is sent: the flow stops at
/// the passphrase.
final class ShareProjectUITests: VaultUITestCase {
    @MainActor
    func testSharingProductionIsConfirmedAndMakesThePassphraseFile() throws {
        let app = launch()
        let sidebar = try onboard(app)
        revealRepositories(of: "example-org", in: sidebar)
        click(sidebarRow("api-service", in: sidebar))
        click(app.buttons[AccessibilityID.Main.importRepository])
        let imported = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.buttons[AccessibilityID.Main.importRepository]
        )
        XCTAssertEqual(XCTWaiter().wait(for: [imported], timeout: timeout), .completed, "The import never finished")

        app.typeKey("s", modifierFlags: [.option, .command])
        let production = app.checkBoxes[AccessibilityID.Share.stage("production")]
        let staging = app.checkBoxes[AccessibilityID.Share.stage("staging")]
        XCTAssertTrue(production.waitForExistence(timeout: timeout))
        XCTAssertEqual(production.value as? Int, 0, "production is checked by default")
        XCTAssertEqual(staging.value as? Int, 1)
        click(production)
        let checked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 1"), object: production)
        XCTAssertEqual(XCTWaiter().wait(for: [checked], timeout: timeout), .completed)

        click(app.buttons[AccessibilityID.Share.continueToSendTo])
        let note = app.descendants(matching: .any)[AccessibilityID.Share.productionNote]
        XCTAssertTrue(note.waitForExistence(timeout: timeout))
        // The note combines into one static text, whose words are its value on macOS.
        let noteText = try XCTUnwrap(note.value as? String)
        XCTAssertTrue(noteText.contains("api-service · production"), noteText)

        click(app.buttons[AccessibilityID.Share.create])
        type(password, into: app.secureTextFields[AccessibilityID.Share.password])
        click(app.buttons[AccessibilityID.Share.passwordContinue])

        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.Share.passphrase].waitForExistence(timeout: timeout))
        let saved = app.checkBoxes[AccessibilityID.Share.passphraseSaved]
        XCTAssertTrue(saved.waitForExistence(timeout: timeout))
        let airDrop = app.buttons[AccessibilityID.Share.airDrop]
        if airDrop.exists {
            XCTAssertFalse(airDrop.isEnabled, "AirDrop is offered before the passphrase is saved")
            click(saved)
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: airDrop)
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: timeout), .completed)
        }
    }
}
