import Foundation
import VaultData

/// Texts of the shared space screens (v0.6.0).
enum SpaceCopy {
    static let repositoryScope = String(localized: "spaces.scope.repository", defaultValue: "Repository")

    static let shareEyebrow = String(localized: "spaces.share.eyebrow", defaultValue: "Share with Teammates")
    static let shareTitle = String(localized: "spaces.share.title", defaultValue: "Keep this scope in sync")
    static let sharePrimary = String(localized: "spaces.share.primary", defaultValue: "Share")
    static let shareExplanation = String(
        localized: "spaces.share.explanation",
        defaultValue: "Every push to this scope becomes a version your teammates get Mac to Mac, with its value, author and time. Before anyone pushes, FX Vault checks they have the latest version. No server is involved: GitHub only holds a small version marker."
    )
    static let shareTeammates = String(localized: "spaces.share.teammates", defaultValue: "Teammates")
    static let shareNoTeammates = String(
        localized: "spaces.share.noTeammates",
        defaultValue: "Pair with a teammate first, in Preferences › Teammates."
    )
    static let shareReason = String(localized: "spaces.share.reason", defaultValue: "Note")
    static let shareReasonPrompt = String(localized: "spaces.share.reason.prompt", defaultValue: "Optional. Shown in the history.")
    static let shareDone = String(
        localized: "spaces.share.done",
        defaultValue: "Shared. Your teammates get it the next time your Macs meet, nearby or at their address."
    )
    static let showSpace = String(localized: "spaces.share.show", defaultValue: "Show Shared Scope")

    static func notReadyPending(_ names: [String]) -> String {
        String(
            localized: "spaces.share.notReady.pending",
            defaultValue: "Sync these first, so the first version matches GitHub: \(names.formatted())."
        )
    }

    static func notReadyMissing(_ names: [String]) -> String {
        String(
            localized: "spaces.share.notReady.missing",
            defaultValue: "Fill these secret values first (GitHub never returns them): \(names.formatted())."
        )
    }

    // MARK: - Space sheet

    static let spaceEyebrow = String(localized: "spaces.sheet.eyebrow", defaultValue: "Shared with Teammates")
    static let historyTab = String(localized: "spaces.sheet.history", defaultValue: "History")
    static let membersTab = String(localized: "spaces.sheet.members", defaultValue: "Members")

    static func subtitle(version: Int64, members: Int) -> String {
        String(localized: "spaces.sheet.subtitle", defaultValue: "v\(version) · \(members) members")
    }

    static func versionTitle(_ version: SpaceVersionSummaryModel) -> String {
        switch version.kind {
        case .shared:
            String(localized: "spaces.history.shared", defaultValue: "v\(version.version) · Shared by \(version.authorName)")
        case .published:
            String(localized: "spaces.history.published", defaultValue: "v\(version.version) · Pushed by \(version.authorName)")
        case .members:
            String(localized: "spaces.history.members", defaultValue: "v\(version.version) · Members changed by \(version.authorName)")
        }
    }

    static func itemVersionTitle(_ item: SpaceItemVersionModel) -> String {
        item.isRemoved
            ? String(localized: "spaces.item.removed", defaultValue: "v\(item.version) · removed by \(item.authorName)")
            : String(localized: "spaces.item.changed", defaultValue: "v\(item.version) · \(item.authorName)")
    }

    static let reveal = String(localized: "spaces.item.reveal", defaultValue: "Reveal")
    static let hide = String(localized: "spaces.item.hide", defaultValue: "Hide")
    static let restore = String(localized: "spaces.item.restore", defaultValue: "Restore This Value")
    static let restored = String(
        localized: "spaces.item.restored",
        defaultValue: "Restored as a local change. Sync to make it the next version."
    )
    static let revealPasswordPrompt = String(
        localized: "spaces.item.reveal.password",
        defaultValue: "Enter your master password to reveal an older value."
    )
    static let noValue = String(localized: "spaces.item.noValue", defaultValue: "No value in this version")

    static let thisMac = String(localized: "spaces.members.thisMac", defaultValue: "This Mac")
    static let notPaired = String(localized: "spaces.members.notPaired", defaultValue: "Not paired on this Mac")
    static let addMembers = String(localized: "spaces.members.add", defaultValue: "Add Teammates")
    static let remove = String(localized: "spaces.members.remove", defaultValue: "Remove…")
    static let removedNotice = String(
        localized: "spaces.members.removedNotice",
        defaultValue: "You are no longer a member of this scope: new versions stay with the members."
    )

    static func removeTitle(_ name: String) -> String {
        String(localized: "spaces.members.remove.title", defaultValue: "Remove \(name) from this scope?")
    }

    static let removeMessage = String(
        localized: "spaces.members.remove.message",
        defaultValue: "The members get a new key, so new versions are hidden from them. What they already received stays with them: rotate those secrets on GitHub."
    )

    static func rotationChecklist(_ names: [String]) -> String {
        names.isEmpty
            ? String(localized: "spaces.members.rotate.none", defaultValue: "Removed. No secret of this scope ever reached them.")
            : String(
                localized: "spaces.members.rotate",
                defaultValue: "Removed. They received these secrets; rotate them on GitHub: \(names.formatted())."
            )
    }

    static let getUpdates = String(localized: "spaces.getUpdates", defaultValue: "Get Updates from Teammates")

    static func chip(version: Int64, isPublishing: Bool) -> String {
        isPublishing
            ? String(localized: "spaces.chip.publishing", defaultValue: "Shared · v\(version) · publishing")
            : String(localized: "spaces.chip", defaultValue: "Shared · v\(version)")
    }

    static let chipHelp = String(
        localized: "spaces.chip.help",
        defaultValue: "Shared with teammates: show its history and members"
    )
    static let shareMenu = String(localized: "spaces.menu.share", defaultValue: "Share with Teammates…")
    static let showMenu = String(localized: "spaces.menu.show", defaultValue: "Shared with Teammates…")
}
