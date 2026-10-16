import Foundation
import VaultData

nonisolated extension SpaceRepositoryError: PresentableError {
    var errorPresentation: ErrorPresentationModel {
        switch self {
        case .vault(.locked):
            ErrorPresentationModel(
                title: String(localized: "spaces.error.locked.title", defaultValue: "FX Vault is locked"),
                message: String(localized: "spaces.error.locked.message", defaultValue: "Unlock FX Vault to work with shared scopes.")
            )
        case .github(let error):
            error.presentation
        case .config(let error):
            error.presentation
        case .scopeNotReady:
            ErrorPresentationModel(
                title: String(localized: "spaces.error.notReady.title", defaultValue: "Sync this scope first"),
                message: String(
                    localized: "spaces.error.notReady.message",
                    defaultValue: "A shared scope starts from what GitHub holds. Push its pending changes and fill every missing secret value, then share it."
                )
            )
        case .alreadyShared:
            ErrorPresentationModel(
                title: String(localized: "spaces.error.alreadyShared.title", defaultValue: "Already shared"),
                message: String(localized: "spaces.error.alreadyShared.message", defaultValue: "This scope is already shared with teammates.")
            )
        case .sharedOnGitHub:
            ErrorPresentationModel(
                title: String(localized: "spaces.error.sharedOnGitHub.title", defaultValue: "Someone shares this scope already"),
                message: String(
                    localized: "spaces.error.sharedOnGitHub.message",
                    defaultValue: "GitHub shows that a teammate shares this scope. Ask them to add you; you get every version when your Macs meet."
                )
            )
        case .gate(let decision):
            ErrorPresentationModel(
                title: String(localized: "spaces.error.gate.title", defaultValue: "Not now"),
                message: SyncCopy.spaceBlock(decision)
            )
        case .notAMember:
            ErrorPresentationModel(
                title: String(localized: "spaces.error.notAMember.title", defaultValue: "Not a member"),
                message: SyncCopy.spaceBlock(.notAMember)
            )
        case .teammateNotFound:
            ErrorPresentationModel(
                title: String(localized: "spaces.error.teammate.title", defaultValue: "Teammate not found"),
                message: String(localized: "spaces.error.teammate.message", defaultValue: "Pair with the teammate first, in Preferences › Teammates.")
            )
        case .invalidMembers:
            ErrorPresentationModel(
                title: String(localized: "spaces.error.members.title", defaultValue: "Can't change the members"),
                message: String(
                    localized: "spaces.error.members.message",
                    defaultValue: "A shared scope keeps at least this Mac. To stop sharing, ask the others to remove you."
                )
            )
        case .repositoryNotOnGitHub:
            ErrorPresentationModel(
                title: String(localized: "spaces.error.notOnGitHub.title", defaultValue: "Not on GitHub yet"),
                message: String(localized: "spaces.error.notOnGitHub.message", defaultValue: "Sync the repository to GitHub first, then share it.")
            )
        case .log, .spaceNotFound:
            ErrorPresentationModel(
                title: String(localized: "spaces.error.log.title", defaultValue: "The shared scope's history can't be read"),
                message: String(
                    localized: "spaces.error.log.message",
                    defaultValue: "A stored version did not pass its checks. Nothing was changed."
                )
            )
        case .vault, .store, .unexpected:
            ErrorPresentationModel(
                title: String(localized: "spaces.error.title", defaultValue: "Something went wrong"),
                message: String(localized: "spaces.error.message", defaultValue: "Nothing was changed. Try again.")
            )
        }
    }
}
