import XCTest

/// The smoke flow (tasks/todo.md B0): onboarding to a main window listing the scripted org.
/// The UITesting app always starts on a new throwaway vault with a scripted gh (App/UITesting),
/// so no real vault, keychain item, account or network is touched.
final class OnboardingSmokeTests: XCTestCase {
    private let password = "Tq9#vL2!mZ7@xR4$kW8-ui"
    private let timeout: TimeInterval = 30
    // Limits.recoveryKeyGroupCount and Limits.recoveryConfirmGroupCount (VaultCore).
    private let recoveryKeyGroupCount = 14
    private let confirmGroupCount = 2

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testOnboardingReachesTheMainWindow() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)"]
        app.launch()

        click(app.buttons[AccessibilityID.Onboarding.createVault])
        type(password, into: app.secureTextFields[AccessibilityID.NewPassword.password])
        type(password, into: app.secureTextFields[AccessibilityID.NewPassword.confirmation])
        click(app.buttons[AccessibilityID.Onboarding.passwordContinue])

        let groups = recoveryKeyGroups(in: app)
        XCTAssertEqual(groups.count, recoveryKeyGroupCount)
        click(app.buttons[AccessibilityID.Onboarding.recoveryKeySaved])

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
        click(app.buttons[AccessibilityID.Onboarding.openVault])

        let sidebar = app.descendants(matching: .any)[AccessibilityID.Main.sidebar]
        XCTAssertTrue(sidebar.waitForExistence(timeout: timeout))
        for name in ["owner-a", "example-org", "api-service"] {
            // Owner headers and repository rows are buttons, and section labels are uppercased.
            let row = sidebar.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", name)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: timeout), "\(name) is not in the sidebar")
        }
        XCTAssertFalse(sidebar.descendants(matching: .any)["Could not be listed"].exists)
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
    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "\(field) never appeared")
        field.click()
        field.typeText(text)
    }

    /// Waits for the button to exist and be enabled (the view model enables it asynchronously).
    @MainActor
    private func click(_ button: XCUIElement) {
        XCTAssertTrue(button.waitForExistence(timeout: timeout), "\(button) never appeared")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: button)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: timeout), .completed)
        button.click()
    }
}
