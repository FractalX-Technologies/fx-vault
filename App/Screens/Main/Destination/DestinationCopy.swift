import Foundation
import VaultCore
import VaultData

/// The text of the destination screens (v0.8.0). Names only, never values.
nonisolated enum DestinationCopy {
    // MARK: Scope column

    static var overviewTitle: String {
        String(localized: "destination.overview.title", defaultValue: "Overview")
    }

    static var overviewHelp: String {
        String(
            localized: "destination.overview.help",
            defaultValue: "Every name a stage needs, across GitHub and the runtime destinations"
        )
    }

    static var runtimeSection: String {
        String(localized: "destination.section.runtime", defaultValue: "Runtime")
    }

    static var experimentalTag: String {
        String(localized: "destination.experimental", defaultValue: "Experimental")
    }

    static var experimentalHelp: String {
        String(
            localized: "destination.experimental.help",
            defaultValue: "Destinations are new: Sync, Refresh and the Overview may still change."
        )
    }

    static var addDestination: String {
        String(localized: "destination.add", defaultValue: "Add Destination")
    }

    static var addDestinationHelp: String {
        String(
            localized: "destination.add.help",
            defaultValue: "Add an Azure Key Vault, a Supabase project or a Vercel environment this repository's code reads at runtime"
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
        case .supabase:
            String(
                localized: "destination.rules.supabase",
                defaultValue: "Secrets only, for Edge Functions. Supabase never returns values, so FX Vault compares digests. Names starting with SUPABASE_ are reserved."
            )
        case .vercel:
            String(
                localized: "destination.rules.vercel",
                defaultValue: "Secrets are encrypted variables, variables are plain. A variable shared with other environments changes for all of them. NEXT_PUBLIC_ names are public in the browser."
            )
        }
    }

    static var connectionMissing: String {
        String(
            localized: "destination.detail.connectionMissing",
            defaultValue: "This destination has no connection. Choose one in its settings before the next Sync."
        )
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

    static var markPublic: String {
        String(localized: "destination.table.markPublic", defaultValue: "Mark as Public")
    }

    static var unmarkPublic: String {
        String(localized: "destination.table.unmarkPublic", defaultValue: "Not Meant to Be Public")
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
