import XCTest

/// Notes editing (1.0 N2; boards Place-Edit, Place-SecretValue, Place-Review): a click on a line
/// opens the editor, a typed variable and a secret set in Set value… go through Review ⌘S, and
/// Save leaves them pending in the notes for the next Sync (nothing is written to GitHub).
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

        // A click on BASE_URL's line (4, under "# Variables") edits the notes, the caret at its end.
        click(notes.descendants(matching: .any)[AccessibilityID.Place.notesLine(4)])
        let editor = app.textViews[AccessibilityID.Place.notesEditor]
        XCTAssertTrue(editor.waitForExistence(timeout: timeout), "A click on a line opened no editor")

        editor.typeKey(.return, modifierFlags: [])
        editor.typeText("LOG_FORMAT=json")
        // A new line under "# Secrets": ⌘↑, the end of the heading's line, Return.
        editor.typeKey(.upArrow, modifierFlags: .command)
        editor.typeKey(.rightArrow, modifierFlags: .command)
        editor.typeKey(.return, modifierFlags: [])
        editor.typeText("API_KEY=")
        // A secret's value is never typed into the text: its first key opens Set value… with it.
        editor.typeText("u")
        let value = app.textViews[AccessibilityID.ItemEditor.value]
        XCTAssertTrue(value.waitForExistence(timeout: timeout), "The key after `=` opened no Set value…")
        app.typeText("i-test-secret")
        XCTAssertEqual(value.value as? String, "ui-test-secret", "Set value… lost the key that opened it")
        click(app.buttons[AccessibilityID.Place.notesValueDone])
        XCTAssertFalse((editor.value as? String ?? "").contains("ui-test-secret"), "The value is in the notes' text")
        let status = app.staticTexts[AccessibilityID.Place.notesEditStatus]
        XCTAssertTrue(status.waitForExistence(timeout: timeout), "The header counts no changes")
        XCTAssertTrue((status.value as? String ?? "").contains("2"), "The header does not count both lines")

        app.typeKey("s", modifierFlags: .command)
        let save = app.buttons[AccessibilityID.Place.notesReviewSave]
        XCTAssertTrue(save.waitForExistence(timeout: timeout), "⌘S opened no review")
        let added = app.sheets.firstMatch.staticTexts[AccessibilityID.Place.notesReviewSection("added")]
        XCTAssertTrue((added.value as? String ?? "").contains("2"), "The review does not list both lines")
        attachWindowScreenshot(of: app, named: "notes-review")
        click(save)

        XCTAssertTrue(editor.waitForNonExistence(timeout: timeout), "Save left the editor open")
        XCTAssertTrue(notes.staticTexts["LOG_FORMAT"].waitForExistence(timeout: timeout), "LOG_FORMAT is not in the notes")
        XCTAssertTrue(notes.staticTexts["API_KEY"].exists, "API_KEY is not in the notes")
    }
}
