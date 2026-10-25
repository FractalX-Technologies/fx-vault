import XCTest

/// The base of every UI flow: launches the UITesting app, which always starts on a new throwaway
/// vault with a scripted gh (App/UITesting), so no real vault, keychain item, account or network
/// is touched.
class VaultUITestCase: XCTestCase {
    let password = "Tq9#vL2!mZ7@xR4$kW8-ui"
    let timeout: TimeInterval = 30
    // Limits.recoveryKeyGroupCount and Limits.recoveryConfirmGroupCount (VaultCore).
    let recoveryKeyGroupCount = 14
    let confirmGroupCount = 2

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)"]
        app.launch()
        return app
    }

    /// Creates the vault (password, recovery key, its confirmation), skips the Connect phase and
    /// opens the main window. Returns the sidebar.
    @MainActor
    @discardableResult
    func onboard(_ app: XCUIApplication) throws -> XCUIElement {
        try createVault(app)
        click(app.buttons[AccessibilityID.Connect.notNow])
        return mainSidebar(app)
    }

    /// Creates the vault and stops on the Connect phase.
    @MainActor
    func createVault(_ app: XCUIApplication) throws {
        click(app.buttons[AccessibilityID.Onboarding.createVault])
        type(password, into: app.secureTextFields[AccessibilityID.NewPassword.password])
        type(password, into: app.secureTextFields[AccessibilityID.NewPassword.confirmation])
        click(app.buttons[AccessibilityID.Onboarding.passwordContinue])

        let groups = recoveryKeyGroups(in: app)
        XCTAssertEqual(groups.count, recoveryKeyGroupCount)
        let saved = app.buttons[AccessibilityID.Onboarding.recoveryKeySaved]
        XCTAssertFalse(saved.isEnabled, "Continue waits for \"I saved it offline\"")
        click(app.checkBoxes[AccessibilityID.Onboarding.recoveryKeySavedCheck])
        click(saved)

        let prefix = AccessibilityID.Onboarding.confirmGroupPrefix
        let confirmFields = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        XCTAssertTrue(confirmFields.firstMatch.waitForExistence(timeout: timeout))
        XCTAssertEqual(confirmFields.count, confirmGroupCount)
        for position in 0..<confirmFields.count {
            let field = confirmFields.element(boundBy: position)
            let index = try XCTUnwrap(Int(field.identifier.dropFirst(prefix.count)))
            type(try XCTUnwrap(groups[index]), into: field)
        }
        click(app.buttons[AccessibilityID.Onboarding.confirm])
    }

    /// The main window's sidebar, once it shows.
    @MainActor
    func mainSidebar(_ app: XCUIApplication) -> XCUIElement {
        let sidebar = app.descendants(matching: .any)[AccessibilityID.Main.sidebar]
        XCTAssertTrue(sidebar.waitForExistence(timeout: timeout))
        return sidebar
    }

    /// A sidebar row whose label contains `name`. Owner headers and repository rows are buttons,
    /// and section labels are uppercased.
    @MainActor
    func sidebarRow(_ name: String, in sidebar: XCUIElement) -> XCUIElement {
        sidebar.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", name)).firstMatch
    }

    /// The groups on the recovery key step, by 0-based index. Each label reads "Group N: XXXX".
    @MainActor
    private func recoveryKeyGroups(in app: XCUIApplication) -> [Int: String] {
        let first = app.descendants(matching: .any)[AccessibilityID.Onboarding.recoveryKeyGroup(0)]
        XCTAssertTrue(first.waitForExistence(timeout: timeout))
        var groups: [Int: String] = [:]
        var index = 0
        while true {
            let element = app.descendants(matching: .any)[AccessibilityID.Onboarding.recoveryKeyGroup(index)]
            guard element.exists, let group = element.label.split(separator: ":").last else { break }
            groups[index] = group.trimmingCharacters(in: .whitespaces)
            index += 1
        }
        return groups
    }

    @MainActor
    func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "\(field) never appeared")
        field.click()
        field.typeText(text)
    }

    /// Waits for the element to exist and be enabled (view models enable buttons asynchronously).
    @MainActor
    func click(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element) never appeared")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: timeout), .completed)
        element.click()
    }
}
