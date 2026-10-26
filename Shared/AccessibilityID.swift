/// Accessibility identifiers the XCUITest suite drives. Compiled into the app and into
/// FXVaultUITests, so renaming one breaks the build instead of a UI test at run time.
enum AccessibilityID {
    enum Onboarding {
        static let createVault = "onboarding.welcome.createVault"
        static let passwordContinue = "onboarding.password.continue"
        static let recoveryKeySaved = "onboarding.recoveryKey.saved"
        static let recoveryKeySavedCheck = "onboarding.recoveryKey.savedCheck"
        static let back = "onboarding.back"
        static let confirm = "onboarding.confirm.continue"

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

    /// Allowlisted setup commands (1.0).
    enum Setup {
        static let output = "setup.output"

        static func run(_ command: String) -> String {
            "setup.run.\(command)"
        }
    }

    /// The notch island that unlocks a locked vault (1.0).
    enum Island {
        static let panel = "island"
        static let touchID = "island.touchID"
        static let usePassword = "island.usePassword"
        static let password = "island.password"
        static let recoveryKey = "island.recoveryKey"
        static let unlocked = "island.unlocked"
    }

    /// The Connect phase after onboarding (1.0).
    enum Connect {
        static let importSelected = "connect.continue"
        static let notNow = "connect.notNow"
        static let summary = "connect.summary"
        static let openVault = "connect.summary.continue"
        static let back = "connect.back"
        /// **Continue** on the GitHub step: to the Azure step.
        static let toAzure = "connect.github.continue"
        static let skipAzure = "connect.azure.skip"
        static let azureRequirement = "connect.azure.requirement"
        static let azureCheckAgain = "connect.azure.checkAgain"
        static let stepCounter = "connect.stepCounter"

        /// The checkbox of a source row (`ConnectViewModel.Source.id`).
        static func source(_ id: String) -> String {
            "connect.source.\(id)"
        }

        /// The checkbox of a Key Vault row (`ConnectAzureModel.Vault.id`).
        static func vault(_ id: String) -> String {
            "connect.vault.\(id)"
        }
    }

    /// The new master password fields (onboarding, recovery reset, change password).
    enum NewPassword {
        static let password = "newPassword.password"
        static let confirmation = "newPassword.confirmation"
    }

    enum Main {
        static let sidebar = "main.sidebar"
        static let importRepository = "main.import"
        static let importOrganization = "main.importOrganization"
        static let organizationTable = "main.organizationTable"
        /// The toolbar's path of the selected place (1.0).
        static let breadcrumb = "main.breadcrumb"

        /// An environment row nested under the selected repository in the sidebar tree (1.0).
        static func environment(_ name: String) -> String {
            "main.environment.\(name)"
        }

        /// A Key Vault of its own under AZURE KEY VAULT in the sidebar (1.0).
        static func keyVault(_ name: String) -> String {
            "main.keyVault.\(name)"
        }

        /// An organization's owner node in the sidebar: selecting it opens its secrets and
        /// variables (1.0).
        static func organization(_ login: String) -> String {
            "main.organization.\(login)"
        }

        /// The search field at the top of the sidebar (⌘F, 1.0).
        static let sidebarSearch = "main.sidebarSearch"

        /// "Show N more" under an owner node: its repositories not in the vault (1.0).
        static func showMore(_ login: String) -> String {
            "main.showMore.\(login)"
        }

        /// The chevron that opens or closes an owner node (1.0).
        static func ownerToggle(_ login: String) -> String {
            "main.ownerToggle.\(login)"
        }

        /// The toolbar's search button that opens the ⌘K jump palette (1.0).
        static let jumpAnywhere = "main.jumpAnywhere"
    }

    /// A place's header (1.0 D6c3): its "kind · parent · counts" line and ⋯ More.
    enum Place {
        static let subline = "place.subline"
        static let more = "place.more"
    }

    /// The ⌘K jump palette (1.0).
    enum Jump {
        static let palette = "jump.palette"
        static let field = "jump.field"
    }

    /// The item editor sheets (repository, folder, destination and organization items).
    enum ItemEditor {
        static let name = "itemEditor.name"
        static let value = "itemEditor.value"
    }

    /// Preferences › Accounts.
    enum Accounts {
        /// An organization row of an account (its login, then its access chip).
        static func organization(_ login: String) -> String {
            "accounts.organization.\(login)"
        }
    }

    /// Share Project and its "Confirm it's you" step.
    enum Share {
        static let continueToSendTo = "share.continue"
        static let create = "share.create"
        static let productionNote = "share.productionNote"
        static let password = "share.reauth.password"
        static let passwordContinue = "share.reauth.continue"
        static let passphrase = "share.passphrase"
        static let passphraseSaved = "share.passphraseSaved"
        static let airDrop = "share.airDrop"

        /// The checkbox of the stage named `name` (an environment name such as `production`).
        static func stage(_ name: String) -> String {
            "share.stage.\(name)"
        }
    }
}
