import SharingKit
import VaultCore

/// The replay warnings of a share import (§9.5); any of them needs an explicit confirmation.
extension ShareReplayWarning {
    var localizedMessage: String {
        switch self {
        case .alreadyImported:
            String(localized: "share.replay.alreadyImported", defaultValue: "You already imported this share.")
        case .olderThanMaxAge:
            String(
                localized: "share.replay.old",
                defaultValue: "This share was created more than \(Timeouts.shareReplayMaxAge.wholeDays) days ago."
            )
        case .olderThanLocalChanges:
            String(
                localized: "share.replay.olderThanLocal",
                defaultValue: "Some items in your vault changed after this share was created."
            )
        }
    }
}
