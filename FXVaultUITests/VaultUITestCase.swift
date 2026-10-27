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

    /// The app's appearance, set for its process only (the Mac's own setting is never changed).
    enum Appearance {
        case system
        case light
        case dark

        var launchArguments: [String] {
            switch self {
            case .system: []
            case .light: ["-NSRequiresAquaSystemAppearance", "YES"]
            case .dark: ["-AppleInterfaceStyle", "Dark"]
            }
        }
    }

    @MainActor
    func launch(appearance: Appearance = .system) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)"] + appearance.launchArguments
        app.launch()
        return app
    }

    /// Keeps the main window as drawn (toolbar, sidebar and detail) in the test report, to compare
    /// with the boards.
    @MainActor
    func attachWindowScreenshot(of app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
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

    /// A sidebar row whose label contains `name`: an owner node, a repository or an environment.
    @MainActor
    func sidebarRow(_ name: String, in sidebar: XCUIElement) -> XCUIElement {
        sidebar.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", name)).firstMatch
    }

    /// Opens an owner node and its "Show N more": owners start collapsed and list only the
    /// repositories in the vault (1.0), so a repository to import needs both.
    @MainActor
    func revealRepositories(of owner: String, in sidebar: XCUIElement) {
        click(sidebar.buttons[AccessibilityID.Main.ownerToggle(owner)])
        click(sidebar.buttons[AccessibilityID.Main.showMore(owner)])
    }

    /// ⌘F, then types into whatever has the focus: the text lands in the sidebar's search field
    /// only if ⌘F focused it.
    @MainActor
    func searchSidebar(for text: String, in app: XCUIApplication) {
        let field = app.textFields[AccessibilityID.Main.sidebarSearch]
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "The sidebar has no search field")
        app.typeKey("f", modifierFlags: .command)
        type(text, intoFocused: field, in: app)
    }

    /// ⌘F with the sidebar hidden (View › Hide Sidebar, ⌃⌘S): Edit › Find must bring it back.
    /// A hidden column leaves the accessibility tree, so the field is looked for after ⌘F.
    @MainActor
    func searchHiddenSidebar(for text: String, in app: XCUIApplication) {
        let field = app.textFields[AccessibilityID.Main.sidebarSearch]
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false OR isHittable == false"), object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [hidden], timeout: timeout), .completed, "The sidebar is not hidden")
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "⌘F did not bring the sidebar back")
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [shown], timeout: timeout), .completed, "⌘F did not bring the sidebar back")
        type(text, intoFocused: field, in: app)
    }

    /// Types into whatever has the focus: the text lands in `field` only if it has the focus.
    @MainActor
    private func type(_ text: String, intoFocused field: XCUIElement, in app: XCUIApplication) {
        app.typeText(text)
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [typed], timeout: timeout), .completed, "⌘F did not focus the search field")
    }

    /// A confirmation dialog's button. The Touch Bar repeats it, disabled, under the same title,
    /// so a plain `app.buttons[title]` finds that copy first and never becomes enabled.
    @MainActor
    func dialogButton(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier BEGINSWITH %@", title, "action-button")).firstMatch
    }

    /// Waits until the toolbar path (`AccessibilityID.Main.breadcrumb`) ends with `suffix`.
    @MainActor
    func expect(_ path: XCUIElement, toEndWith suffix: String) {
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label ENDSWITH %@ OR value ENDSWITH %@", suffix, suffix),
            object: path
        )
        XCTAssertEqual(XCTWaiter().wait(for: [shown], timeout: timeout), .completed, "The path never ended with \(suffix)")
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

    /// Clicks the menu bar item and returns its open menu. A `MenuBarExtra` doesn't pass
    /// `.accessibilityIdentifier` to its menu items: find them by title.
    @MainActor
    func openMenuBarMenu(_ app: XCUIApplication) -> XCUIElement {
        let item = app.statusItems.firstMatch
        click(item)
        let menu = item.menus.firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: timeout), "The menu bar item opened no menu")
        return menu
    }

    /// The Debug build's menu bar item for the main window ("FX Vault Dev").
    let openFXVaultTitle = "Open FX Vault Dev"

    /// A lock leaves nothing on screen (1.0.2): the island waits until FX Vault is opened again.
    @MainActor
    func expectNoIslandAfterLock(_ app: XCUIApplication) {
        let island = app.descendants(matching: .any)[AccessibilityID.Island.panel]
        XCTAssertFalse(island.waitForExistence(timeout: 3), "Locking showed the island by itself")
    }

    /// Locks with ⌃⌘L, then opens the island from the menu bar's Open FX Vault.
    @MainActor
    func lockThenOpenIsland(_ app: XCUIApplication) {
        app.typeKey("l", modifierFlags: [.control, .command])
        expectNoIslandAfterLock(app)
        click(openMenuBarMenu(app).menuItems[openFXVaultTitle])
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
