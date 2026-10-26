import Foundation
import VaultCore

/// Words and commands of Settings › Accounts › Azure (1.0 S1b; board Settings-Accounts).
nonisolated enum AzureAccountsCopy {
    static let section = String(localized: "settings.accounts.azure.section", defaultValue: "Azure")
    static let signedIn = String(localized: "settings.accounts.azure.signedIn", defaultValue: "Signed in")
    static let notSignedIn = String(localized: "settings.accounts.azure.notSignedIn", defaultValue: "Not signed in")
    static let defaultTenant = String(localized: "settings.accounts.azure.defaultTenant", defaultValue: "Default tenant")
    static let noVaults = String(localized: "settings.accounts.azure.noVaults", defaultValue: "No vaults in FX Vault")
    static let chooseVaults = String(localized: "settings.accounts.azure.chooseVaults", defaultValue: "Choose Vaults…")
    static let signOut = String(localized: "settings.accounts.azure.signOut", defaultValue: "Sign out of Azure")
    static let chooseTitle = String(localized: "settings.accounts.azure.choose.title", defaultValue: "Choose vaults")
    static let add = String(localized: "settings.accounts.azure.choose.add", defaultValue: "Add Vaults")

    /// Interactive in Terminal, so Settings gives them to copy and never runs them.
    static let logoutCommand = "az logout"

    /// `az login --tenant <id>`; plain `az login` for a tenant that is neither an id nor a
    /// domain, so nothing else ever lands in the command the user pastes into Terminal.
    static func loginCommand(tenantID: String?) -> String {
        guard let tenantID, DestinationRules.isValidTenantID(tenantID) else { return DestinationSyncCopy.azLoginCommand }
        return "\(DestinationSyncCopy.azLoginCommand) --tenant \(tenantID)"
    }

    /// "Example Production · 2 vaults".
    static func subscriptionVaults(_ name: String, count: Int) -> String {
        String(inflected: AttributedString(
            localized: "settings.accounts.azure.subscriptionVaults",
            defaultValue: "\(name) · ^[\(count) vault](inflect: true)"
        ))
    }

    /// Vaults saved before FX Vault kept their subscription (1.0 D6c6).
    static func otherVaults(_ count: Int) -> String {
        String(inflected: AttributedString(
            localized: "settings.accounts.azure.otherVaults",
            defaultValue: "^[\(count) other vault](inflect: true)"
        ))
    }

    static func vaults(_ count: Int) -> String {
        String(inflected: AttributedString(
            localized: "settings.accounts.azure.vaults",
            defaultValue: "^[\(count) vault](inflect: true)"
        ))
    }

    /// "Not signed in · Example Labs · 1 vault".
    static func notSignedIn(_ summary: String) -> String {
        String(localized: "settings.accounts.azure.notSignedIn.line", defaultValue: "Not signed in · \(summary)")
    }

    static func copied(_ command: String) -> String {
        String(localized: "settings.accounts.azure.copied", defaultValue: "Copied \(command). Run it in Terminal, then Check Again.")
    }

    /// After Add Vaults: "Added 2 vaults with 5 secrets."
    static func added(vaults: Int, secrets: Int) -> String {
        String(inflected: AttributedString(
            localized: "settings.accounts.azure.added",
            defaultValue: "Added ^[\(vaults) vault](inflect: true) with ^[\(secrets) secret](inflect: true)."
        ))
    }

    static func notRead(_ names: [String]) -> String {
        String(localized: "settings.accounts.azure.notRead", defaultValue: "Could not read \(names.formatted(.list(type: .and))).")
    }
}
