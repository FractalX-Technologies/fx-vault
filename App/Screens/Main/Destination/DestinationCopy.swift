import DestinationKit
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

    /// The footnote under the table (board KV-Place).
    static func rules(for provider: DestinationProvider) -> String {
        switch provider {
        case .azureKeyVault:
            String(
                localized: "destination.rules.keyVault.footnote",
                defaultValue: "Key Vault names use dashes: FX Vault keeps DATABASE_URL and writes DATABASE-URL. Deleted secrets stay recoverable in Key Vault."
            )
        }
    }

    /// "2 changed in Key Vault": Refresh's findings as the header's line (board KV-Place).
    static func changed(_ count: Int, provider: DestinationProvider) -> String {
        String(localized: "destination.detail.changed", defaultValue: "\(count) changed in \(provider.shortTitle)")
    }

    static func reviewHelp(provider: DestinationProvider) -> String {
        String(localized: "destination.detail.review.help", defaultValue: "Keep your version or take \(provider.shortTitle)’s for each change")
    }

    /// The secrets Refresh found that FX Vault leaves out, by reason (board KV-Place).
    static func hidden(_ count: Int, reason: DestinationUnusableReason) -> String {
        switch (reason, count) {
        case (.managed, 1):
            String(localized: "destination.hidden.managed.one", defaultValue: "1 certificate-backed secret is hidden · managed by Key Vault")
        case (.managed, _):
            String(localized: "destination.hidden.managed", defaultValue: "\(count) certificate-backed secrets are hidden · managed by Key Vault")
        case (.disabled, 1):
            String(localized: "destination.hidden.disabled.one", defaultValue: "1 disabled secret is hidden · not editable")
        case (.disabled, _):
            String(localized: "destination.hidden.disabled", defaultValue: "\(count) disabled secrets are hidden · not editable")
        case (.invalidName, 1):
            String(localized: "destination.hidden.invalidName.one", defaultValue: "1 secret is hidden · its name can’t be used in FX Vault")
        case (.invalidName, _):
            String(localized: "destination.hidden.invalidName", defaultValue: "\(count) secrets are hidden · their names can’t be used in FX Vault")
        }
    }

    static func driftBanner(_ count: Int, provider: DestinationProvider) -> String {
        count == 1
            ? String(localized: "destination.detail.drift.one", defaultValue: "1 change in \(provider.title) since your last sync")
            : String(localized: "destination.detail.drift", defaultValue: "\(count) changes in \(provider.title) since your last sync")
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

    // MARK: Errors

    static var syncErrorTitle: String {
        String(localized: "destination.error.title", defaultValue: "The destination could not be reached")
    }
}
