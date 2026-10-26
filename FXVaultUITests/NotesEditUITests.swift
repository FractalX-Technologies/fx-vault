import XCTest

/// Notes editing (1.0 N2; boards Place-Edit, Place-SecretValue, Place-Review): ⋯ More › Edit
/// Notes opens the editor, a typed variable and a secret set in Set value… go through Review ⌘S,
/// and Save leaves them pending in the notes for the next Sync (nothing is written to GitHub).
final class NotesEditUITests: VaultUITestCase {
    @MainActor
    func testTypedLinesBecomePendingChangesAfterReview() throws {
        let app = launch()
        let sidebar = try onboard(app)
        revealRepositories(of: "example-org", in: sidebar)
        click(sidebarRow("api-service", in: sidebar))
        click(app.buttons[AccessibilityID.Main.importRepository])
        let notes = app.descendants(matching: .any)[AccessibilityID.Place.notes]
        XCTAssertTrue(notes.staticTexts["BASE_URL"].waitForExistence(timeout: timeout), "The import never showed the notes")

        click(app.descendants(matching: .any).matching(identifier: AccessibilityID.Place.more).firstMatch)
        click(app.menuItems["Edit Notes"])
        let editor = app.textViews[AccessibilityID.Place.notesEditor]
        XCTAssertTrue(editor.waitForExistence(timeout: timeout), "Edit Notes opened no editor")

        // The caret starts at the end of the text, under the variables.
        editor.typeText("LOG_FORMAT=json")
        // A new line under "# Secrets": ⌘↑, the end of the heading's line, Return.
        editor.typeKey(.upArrow, modifierFlags: .command)
        editor.typeKey(.rightArrow, modifierFlags: .command)
        editor.typeKey(.return, modifierFlags: [])
        editor.typeText("API_KEY=")
        // A secret's value is never typed into the text: the next key opens Set value… instead.
        editor.typeText("x")
        type("ui-test-secret", into: app.textViews[AccessibilityID.ItemEditor.value])
        click(app.buttons[AccessibilityID.Place.notesValueDone])
        XCTAssertFalse((editor.value as? String ?? "").contains("ui-test-secret"), "The value is in the notes' text")

        app.typeKey("s", modifierFlags: .command)
        let save = app.buttons[AccessibilityID.Place.notesReviewSave]
        XCTAssertTrue(save.waitForExistence(timeout: timeout), "⌘S opened no review")
        XCTAssertTrue(app.sheets.firstMatch.staticTexts["Added · 2"].exists, "The review does not list both lines")
        attachWindowScreenshot(of: app, named: "notes-review")
        click(save)

        XCTAssertTrue(editor.waitForNonExistence(timeout: timeout), "Save left the editor open")
        XCTAssertTrue(notes.staticTexts["LOG_FORMAT"].waitForExistence(timeout: timeout), "LOG_FORMAT is not in the notes")
        XCTAssertTrue(notes.staticTexts["API_KEY"].exists, "API_KEY is not in the notes")
    }
}
