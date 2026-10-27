import Foundation

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

        /// A `CommandRow`'s command text.
        static func command(_ command: String) -> String {
            "setup.command.\(command)"
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

    /// The recovery screen's last resort: erase a vault whose password and key are both lost.
    enum Recovery {
        static let forgotKey = "recovery.forgotKey"
        static let eraseConfirmation = "recovery.eraseConfirmation"
        static let erase = "recovery.erase"
    }

    /// In-app Approve through `gh auth refresh` (1.0 B4b).
    enum GHApproval {
        static let sheet = "ghApproval"
        static let code = "ghApproval.code"
        static let copyCode = "ghApproval.copyCode"
        static let openDevicePage = "ghApproval.openDevicePage"
        static let checkAgain = "ghApproval.checkAgain"
        static let cancel = "ghApproval.cancel"
        static let tryAgain = "ghApproval.tryAgain"
        static let status = "ghApproval.status"
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

        /// An Azure subscription's row under Azure in the sidebar (1.0 D6c6), by id: two
        /// subscriptions may share a name.
        static func subscription(_ id: UUID) -> String {
            "main.subscription.\(id.uuidString.lowercased())"
        }

        /// The chevron that opens or closes a subscription (1.0 D6c6).
        static func subscriptionToggle(_ id: UUID) -> String {
            "main.subscriptionToggle.\(id.uuidString.lowercased())"
        }

        /// The toolbar's search button that opens the ⌘K jump palette (1.0).
        static let jumpAnywhere = "main.jumpAnywhere"
    }

    /// A place's header (1.0 D6c3): its "kind · parent · counts" line and ⋯ More.
    enum Place {
        /// The red Delete of the "Delete?" sheet (boards Main2-Delete, Main2-DeleteKeyVault).
        static let deleteConfirm = "place.deleteConfirm"
        static let subline = "place.subline"
        static let more = "place.more"
        static let copyAll = "place.copyAll"
        /// Notes | Table on the header (1.0 B9).
        static let viewMode = "place.viewMode"
        /// A place's notes (1.0 B9; board Main2-Repository).
        static let notes = "place.notes"
        /// The notes editor's text, Set value…'s Done and the edit's header buttons (1.0 N2).
        static let notesEditor = "place.notesEditor"
        static let notesValueDone = "place.notesValueDone"
        static let notesEditCancel = "place.notesEditCancel"
        static let notesReview = "place.notesReview"
        static let notesReviewSave = "place.notesReviewSave"
        /// The edit header's "4 unsaved changes" or "Fix 4 lines to save".
        static let notesEditStatus = "place.notesEditStatus"

        /// A line of the read notes that a click edits, by its number (from 1).
        static func notesLine(_ number: Int) -> String {
            "place.notesLine.\(number)"
        }

        /// A Review section's title, by ``NotesReviewModel/Section`` id: added, changed, removed.
        static func notesReviewSection(_ id: String) -> String {
            "place.notesReview.\(id)"
        }
    }

    /// The ⌘K jump palette (1.0).
    enum Jump {
        static let palette = "jump.palette"
        static let field = "jump.field"
    }

    /// The quick vault from the notch (1.0 Q1; boards QuickVault-*). Each line's Copy shares
    /// ``copy``; its label names the line.
    enum QuickVault {
        static let panel = "quickVault"
        static let field = "quickVault.field"
        static let expand = "quickVault.expand"
        static let lines = "quickVault.lines"
        static let copy = "quickVault.copy"
        static let confirm = "quickVault.confirm"
    }

    /// The item editor sheets (repository, folder, destination and organization items).
    enum ItemEditor {
        static let name = "itemEditor.name"
        static let value = "itemEditor.value"
    }

    /// Add file secret (1.0 F1; board Place-FileSheet).
    enum FileSecret {
        static let name = "fileSecret.name"
        /// The file row: its name and facts, and Choose….
        static let file = "fileSecret.file"
        static let choose = "fileSecret.choose"
        static let limits = "fileSecret.limits"
        static let add = "fileSecret.add"
    }

    /// Preferences › Accounts.
    enum Accounts {
        /// An organization row of an account (its login, then its access chip).
        static func organization(_ login: String) -> String {
            "accounts.organization.\(login)"
        }

        static let addAccount = "accounts.addAccount"
        static let addAccountCheckAgain = "accounts.addAccount.checkAgain"
        static let unmappedCheckAgain = "accounts.unmapped.checkAgain"

        /// An Azure tenant row (its lowercased id; empty for the default tenant), 1.0 S1b.
        static func azureTenant(_ id: String) -> String {
            "accounts.azure.tenant.\(id)"
        }

        static func azureChooseVaults(_ id: String) -> String {
            "accounts.azure.chooseVaults.\(id)"
        }

        static let azureSignOut = "accounts.azure.signOut"
        static let azureCheckAgain = "accounts.azure.checkAgain"
        static let azureAddVaults = "accounts.azure.addVaults"
    }

    /// The menu bar item's menu (1.0 M1).
    enum MenuBar {
        static let quickVault = "menuBar.quickVault"
        static let open = "menuBar.open"
        static let reviewSync = "menuBar.reviewSync"
        static let lockNow = "menuBar.lockNow"
        static let settings = "menuBar.settings"
        static let quit = "menuBar.quit"
    }

    /// Settings › General, Security and Advanced.
    enum Settings {
        static let quickVaultShortcut = "settings.quickVaultShortcut"
        static let resetVault = "settings.resetVault"
        static let revealVaultFolder = "settings.revealVaultFolder"
    }

    /// Share Project and its "Confirm it's you" step.
    enum Share {
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
