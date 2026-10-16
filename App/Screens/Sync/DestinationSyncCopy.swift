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
        case .connectionMissing:
            String(
                localized: "sync.destination.blocked.connection",
                defaultValue: "The destination has no connection. Choose one in its settings."
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
        case .publicCredential(let prefix):
            String(
                localized: "sync.destination.blocked.public",
                defaultValue: "\(prefix) names are public in the browser, and this value looks like a secret. Change the value, or Mark as Public in the destination."
            )
        case .invalidName(let error):
            error.localizedMessage
        }
    }

    static func publicWarning(name: String, prefix: String, destination: String) -> String {
        String(
            localized: "sync.destination.publicWarning",
            defaultValue: "\(name) in \(destination) is public (\(prefix)) and its value looks like a token. Fine for a key meant to be public."
        )
    }

    static func sharedVariable(name: String, others: [String]) -> String {
        String(
            localized: "sync.destination.shared",
            defaultValue: "\(name) is shared with \(others.joined(separator: ", ")) on Vercel: they get the new value too."
        )
    }

    static func deletionTitle(name: String, destination: String) -> String {
        String(localized: "sync.destination.deletion", defaultValue: "Delete \(name) in \(destination)")
    }

    static func deletionKeepsOthers(_ others: [String]) -> String {
        String(
            localized: "sync.destination.deletion.keeps",
            defaultValue: "Only this environment: \(others.joined(separator: ", ")) keep it."
        )
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
