import DestinationKit
import Foundation
import VaultCore
import VaultData

/// The text of destination changes in the Sync sheet (v0.8.0). Names only.
nonisolated enum DestinationSyncCopy {
    static let azLoginCommand = "az login"
    static let azInstallCommand = "brew install azure-cli"

    static func sentence(writes: Int, deletions: Int) -> String {
        switch (writes, deletions) {
        case (_, 0):
            String(localized: "sync.destination.writes", defaultValue: "\(writes) will push")
        case (0, _):
            String(localized: "sync.destination.deletions", defaultValue: "\(deletions) deleted")
        default:
            String(localized: "sync.destination.writesAndDeletions", defaultValue: "\(writes) will push · \(deletions) deleted")
        }
    }

    static func asRemote(_ remoteName: String) -> String {
        String(localized: "sync.destination.asRemote", defaultValue: "as \(remoteName)")
    }

    static func reason(_ reason: DestinationBlockReason, provider: DestinationProvider) -> String {
        switch reason {
        case .valueMissing:
            String(
                localized: "sync.destination.blocked.valueMissing",
                defaultValue: "The value is not in FX Vault (the provider never returned it). Fill it first."
            )
        case .listingFailed(let error):
            String(
                localized: "sync.destination.blocked.listing",
                defaultValue: "\(provider.title) could not be listed, so nothing is sent there: \(error.localizedMessage(provider: provider))"
            )
        case .remoteChanged:
            String(
                localized: "sync.destination.blocked.remoteChanged",
                defaultValue: "It changed in \(provider.title) since the last sync. Refresh the destination and review the change."
            )
        case .existsRemotely:
            String(
                localized: "sync.destination.blocked.exists",
                defaultValue: "\(provider.title) already has this name. Refresh the destination to keep yours or use theirs."
            )
        case .invalidName(let error):
            error.localizedMessage
        }
    }

    static func deletionTitle(name: String, destination: String) -> String {
        String(localized: "sync.destination.deletion", defaultValue: "Delete \(name) in \(destination)")
    }

    static var confirmed: String {
        String(localized: "sync.destination.confirmed", defaultValue: "Confirmed in the destination")
    }

    static var unconfirmed: String {
        String(
            localized: "sync.destination.unconfirmed",
            defaultValue: "Sent, but the destination did not list it yet. The next Sync sends it again."
        )
    }

    static var skipped: String {
        String(localized: "sync.destination.skipped", defaultValue: "Not sent")
    }
}
