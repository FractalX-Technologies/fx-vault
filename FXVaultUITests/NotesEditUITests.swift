import XCTest

/// Notes editing (1.0 N2; boards Place-Edit, Place-SecretValue, Place-Review): a click on a line
/// opens the editor, a typed variable and a secret set in Set value… go through Review ⌘S, and
/// Save leaves them pending in the notes for the next Sync (nothing is written to GitHub).
final class NotesEditUITests: VaultUITestCase {
    @MainActor
    func testTypedLinesBecomePendingChangesAfterReview() throws {
        let (app, _, notes, editor) = try editBaseURLLine()
        // A new line under "# Secrets": ⌘↑, the end of the heading's line, Return.
        editor.typeKey(.upArrow, modifierFlags: .command)
        editor.typeKey(.rightArrow, modifierFlags: .command)
        editor.typeKey(.return, modifierFlags: [])
        editor.typeText("API_KEY=")
        // A secret's value is never typed into the text: its first key opens Set value… with it.
        editor.typeText("u")
        let value = app.textViews[AccessibilityID.ItemEditor.value]
        XCTAssertTrue(value.appears(within: timeout), "The key after `=` opened no Set value…")
        app.typeText("i-test-secret")
        XCTAssertEqual(value.value as? String, "ui-test-secret", "Set value… lost the key that opened it")
        click(app.buttons[AccessibilityID.Place.notesValueDone])
        XCTAssertFalse((editor.value as? String ?? "").contains("ui-test-secret"), "The value is in the notes' text")
        let status = app.staticTexts[AccessibilityID.Place.notesEditStatus]
        XCTAssertTrue(status.appears(within: timeout), "The header counts no changes")
        XCTAssertTrue((status.value as? String ?? "").contains("2"), "The header does not count both lines")

        app.typeKey("s", modifierFlags: .command)
        let save = app.buttons[AccessibilityID.Place.notesReviewSave]
        XCTAssertTrue(save.appears(within: timeout), "⌘S opened no review")
        let added = app.sheets.firstMatch.staticTexts[AccessibilityID.Place.notesReviewSection("added")]
        XCTAssertTrue((added.value as? String ?? "").contains("2"), "The review does not list both lines")
        attachWindowScreenshot(of: app, named: "notes-review")
        click(save)

        XCTAssertTrue(editor.disappears(within: timeout), "Save left the editor open")
        XCTAssertTrue(notes.staticTexts["LOG_FORMAT"].appears(within: timeout), "LOG_FORMAT is not in the notes")
        XCTAssertTrue(notes.staticTexts["API_KEY"].exists, "API_KEY is not in the notes")
    }

    /// With an unsaved change, another scope asks first: Keep Editing stays in the edit, Discard
    /// leaves it for the scope chosen.
    @MainActor
    func testLeavingWithAnUnsavedChangeAsksFirst() throws {
        let (app, sidebar, _, editor) = try editBaseURLLine()
        let staging = sidebar.buttons[AccessibilityID.Main.environment("staging")]
        let path = app.staticTexts[AccessibilityID.Main.breadcrumb]

        click(staging)
        click(dialogButton("Keep Editing", in: app))
        XCTAssertTrue(editor.exists, "Keep Editing left the edit")
        expect(path, toEndWith: "api-service")

        click(staging)
        click(dialogButton("Discard", in: app))
        XCTAssertTrue(editor.disappears(within: timeout), "Discard kept the editor")
        expect(path, toEndWith: "api-service › staging")
    }

    /// Reveal All (board Place-Reveal): one master password shows every secret under one
    /// countdown, a click on a line copies its value instead of editing, and Hide All masks them.
    @MainActor
    func testRevealAllShowsTheSecretsAndAClickCopiesOne() throws {
        let (app, _, notes, editor) = try editBaseURLLine()
        editor.typeKey(.upArrow, modifierFlags: .command)
        editor.typeKey(.rightArrow, modifierFlags: .command)
        editor.typeKey(.return, modifierFlags: [])
        editor.typeText("API_KEY=")
        editor.typeText("u")
        XCTAssertTrue(app.textViews[AccessibilityID.ItemEditor.value].appears(within: timeout), "No Set value…")
        app.typeText("i-test-secret")
        click(app.buttons[AccessibilityID.Place.notesValueDone])
        app.typeKey("s", modifierFlags: .command)
        click(app.buttons[AccessibilityID.Place.notesReviewSave])
        XCTAssertTrue(notes.staticTexts["API_KEY"].appears(within: timeout), "API_KEY is not in the notes")
        XCTAssertFalse(notes.staticTexts["ui-test-secret"].exists, "The secret shows before Reveal All")

        let revealAll = app.buttons[AccessibilityID.Place.revealAll]
        click(revealAll)
        type(password, into: app.secureTextFields[AccessibilityID.Share.password])
        click(app.buttons[AccessibilityID.Share.passwordContinue])
        XCTAssertTrue(notes.staticTexts["ui-test-secret"].appears(within: timeout), "Reveal All showed no secret")
        XCTAssertTrue(notes.descendants(matching: .any)[AccessibilityID.Place.revealAllBar].exists, "No countdown above the notes")

        // The runner can't read the general pasteboard (macOS privacy); NotesRevealTests checks
        // what lands there.
        click(notes.staticTexts["API_KEY"])
        let copied = notes.descendants(matching: .any)[AccessibilityID.Place.notesCopied]
        XCTAssertTrue(copied.appears(within: timeout), "The line does not say Copied")
        XCTAssertFalse(app.textViews[AccessibilityID.Place.notesEditor].exists, "The click opened the editor")

        click(revealAll)
        XCTAssertTrue(notes.staticTexts["ui-test-secret"].disappears(within: timeout), "Hide All left the secret showing")
    }

    /// api-service imported, a click on BASE_URL's line (4, under "# Variables") and a new line
    /// typed under it: one unsaved change.
    @MainActor
    private func editBaseURLLine() throws -> (app: XCUIApplication, sidebar: XCUIElement, notes: XCUIElement, editor: XCUIElement) {
        let app = launch()
        let sidebar = mainSidebar(app)
        revealRepositories(of: "example-org", in: sidebar)
        click(sidebarRow("api-service", in: sidebar))
        click(app.buttons[AccessibilityID.Main.importRepository])
        let notes = app.descendants(matching: .any)[AccessibilityID.Place.notes]
        XCTAssertTrue(notes.staticTexts["BASE_URL"].appears(within: timeout), "The import never showed the notes")

        click(notes.descendants(matching: .any)[AccessibilityID.Place.notesLine(4)])
        let editor = app.textViews[AccessibilityID.Place.notesEditor]
        XCTAssertTrue(editor.appears(within: timeout), "A click on a line opened no editor")
        editor.typeKey(.return, modifierFlags: [])
        editor.typeText("LOG_FORMAT=json")
        return (app, sidebar, notes, editor)
    }
}
