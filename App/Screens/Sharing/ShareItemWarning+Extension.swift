import SharingKit

/// Notes shown under an incoming item in the import preview (§9.5).
extension ShareItemWarning {
    var localizedMessage: String {
        switch self {
        case .otherKindExists:
            String(
                localized: "share.warning.otherKind",
                defaultValue: "The same name exists here as the other kind (secret or variable). Skipped."
            )
        case .deletedLocally:
            String(
                localized: "share.warning.deletedLocally",
                defaultValue: "Deleted in your vault and waiting for Sync. Skipped."
            )
        case .localChangedSincePackage:
            String(
                localized: "share.warning.localChanged",
                defaultValue: "You changed this after the share was created."
            )
        }
    }
}
