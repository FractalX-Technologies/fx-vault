import SharingKit

nonisolated extension ShareImportBlockReason {
    var localizedMessage: String {
        switch self {
        case .repositoryNotImported:
            String(
                localized: "share.blocked.notImported",
                defaultValue: "The repository is not in your vault yet. Import it from GitHub first."
            )
        case .repositoryNameMismatch:
            String(
                localized: "share.blocked.nameMismatch",
                defaultValue: "The repository in your vault does not match the one in this share."
            )
        case .repositoryIDMismatch:
            String(
                localized: "share.blocked.idMismatch",
                defaultValue: "Your vault has a different repository with this name (it was deleted and re-created on GitHub, or renamed). Nothing can be imported into it."
            )
        }
    }
}
