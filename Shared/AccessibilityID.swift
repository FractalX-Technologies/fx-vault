/// Accessibility identifiers the XCUITest suite drives. Compiled into the app and into
/// FXVaultUITests, so renaming one breaks the build instead of a UI test at run time.
enum AccessibilityID {
    enum Onboarding {
        static let createVault = "onboarding.welcome.createVault"
        static let passwordContinue = "onboarding.password.continue"
        static let recoveryKeySaved = "onboarding.recoveryKey.saved"
        static let confirm = "onboarding.confirm.continue"
        static let openVault = "onboarding.done.open"

        /// A recovery key group on screen; `index` is 0-based. Its label ends with the group.
        static func recoveryKeyGroup(_ index: Int) -> String {
            "onboarding.recoveryKey.group.\(index)"
        }

        /// The field asking for recovery key group `index` (0-based).
        static func confirmGroup(_ index: Int) -> String {
            "\(confirmGroupPrefix)\(index)"
        }

        static let confirmGroupPrefix = "onboarding.confirm.group."
    }

    /// The new master password fields (onboarding, recovery reset, change password).
    enum NewPassword {
        static let password = "newPassword.password"
        static let confirmation = "newPassword.confirmation"
    }

    enum Main {
        static let sidebar = "main.sidebar"
    }
}
