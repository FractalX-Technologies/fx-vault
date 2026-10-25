import Foundation
import VaultCore
import VaultData

/// The text of the destination screens (v0.8.0). Names only, never values.
nonisolated enum DestinationCopy {
    // MARK: Scope column

    static var runtimeSection: String {
        String(localized: "destination.section.runtime", defaultValue: "Runtime")
    }

    static var experimentalTag: String {
        String(localized: "destination.experimental", defaultValue: "Experimental")
    }

    static var experimentalHelp: String {
        String(
            localized: "destination.experimental.help",
            defaultValue: "Destinations are new: Sync and Refresh may still change."
        )
    }

    static var addDestination: String {
        String(localized: "destination.add", defaultValue: "Add Destination")
    }

    static var addDestinationHelp: String {
        String(
            localized: "destination.add.help",
            defaultValue: "Add an Azure Key Vault this repository's code reads at runtime"
        )
    }

    static var settingsMenu: String {
        String(localized: "destination.menu.settings", defaultValue: "Settings…")
    }

    static var removeMenu: String {
        String(localized: "destination.menu.remove", defaultValue: "Remove from FX Vault…")
    }

    static var removeTitle: String {
        String(localized: "destination.remove.title", defaultValue: "Remove this destination?")
    }

    static var removeConfirm: String {
        String(localized: "destination.remove.confirm", defaultValue: "Remove Destination")
    }

    static func removeMessage(_ title: String) -> String {
        String(
            localized: "destination.remove.message",
            defaultValue: "\(title) and its items are removed from FX Vault. Nothing is deleted in the provider, and pending changes are dropped."
        )
    }

    static func valueMissingHelp(_ count: Int) -> String {
        String(
            localized: "destination.valueMissing.help",
            defaultValue: "\(count) secrets have no value in FX Vault"
        )
    }

    // MARK: Detail

    static var eyebrow: String {
        String(localized: "destination.detail.eyebrow", defaultValue: "Destination · Runtime")
    }

    static var refresh: String {
        String(localized: "destination.detail.refresh", defaultValue: "Refresh")
    }

    static var refreshHelp: String {
        String(
            localized: "destination.detail.refresh.help",
            defaultValue: "List the destination and show what changed there since the last sync"
        )
    }

    static var refreshFailedTitle: String {
        String(localized: "destination.detail.refresh.failed", defaultValue: "The destination could not be listed")
    }

    static var stageLabel: String {
        String(localized: "destination.detail.stage", defaultValue: "Stage")
    }

    static var noStage: String {
        String(localized: "destination.detail.noStage", defaultValue: "No stage")
    }

    static var targetLabel: String {
        String(localized: "destination.detail.target", defaultValue: "Target")
    }

    static var rulesLabel: String {
        String(localized: "destination.detail.rules", defaultValue: "Names and values")
    }

    static func rules(for provider: DestinationProvider) -> String {
        switch provider {
        case .azureKeyVault:
            String(
                localized: "destination.rules.keyVault",
                defaultValue: "Secrets only. Key Vault names allow letters, digits and dashes: FX Vault keeps your names and writes DATABASE-URL for DATABASE_URL. Deletes are soft deletes."
            )
        }
    }

    static func driftBanner(_ count: Int, provider: DestinationProvider) -> String {
        count == 1
            ? String(localized: "destination.detail.drift.one", defaultValue: "1 change in \(provider.title) since your last sync")
            : String(localized: "destination.detail.drift", defaultValue: "\(count) changes in \(provider.title) since your last sync")
    }

    static func unusableBanner(_ count: Int) -> String {
        count == 1
            ? String(localized: "destination.detail.unusable.one", defaultValue: "1 item in the destination cannot be used by FX Vault")
            : String(localized: "destination.detail.unusable", defaultValue: "\(count) items in the destination cannot be used by FX Vault")
    }

    static var noDrift: String {
        String(localized: "destination.detail.noDrift", defaultValue: "No changes since your last sync")
    }

    static var review: String {
        String(localized: "destination.detail.review", defaultValue: "Review")
    }

    static var tableEmpty: String {
        String(
            localized: "destination.table.empty",
            defaultValue: "Add one, paste KEY=value lines with ⌘V, import a .env file, or copy items here from a scope or folder."
        )
    }

    static var retiredTitle: String {
        String(localized: "destination.retired.title", defaultValue: "Supabase and Vercel Destinations Removed")
    }

    /// The one-time notice after the 1.0 migration deleted them from the vault (nothing remote).
    static func retiredMessage(_ labels: [String]) -> String {
        String(
            localized: "destination.retired.message",
            defaultValue: "FX Vault 1.0 keeps Azure Key Vault only. These destinations were removed from the vault; nothing was deleted in Supabase or Vercel:\n\(labels.joined(separator: "\n"))"
        )
    }

    static var fillValue: String {
        String(localized: "destination.table.fill", defaultValue: "Fill Value…")
    }

    static var deleteItemsMessage: String {
        String(
            localized: "destination.delete.message",
            defaultValue: "Items already in the destination are deleted there by the next Sync, after you confirm. Their linked copies elsewhere stay."
        )
    }

    // MARK: Errors

    static var syncErrorTitle: String {
        String(localized: "destination.error.title", defaultValue: "The destination could not be reached")
    }
}
