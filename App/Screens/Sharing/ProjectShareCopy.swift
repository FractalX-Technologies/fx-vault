import Foundation
import SharingKit
import VaultCore
import VaultData

/// Text of the project share sheets (v0.9.0): Share Project, the bundle preview of Import Share
/// and Settings › Sharing. Every count has a singular variant (lessons, 2026-10-16).
enum ProjectShareCopy {
    // MARK: - Share sheet (board Share-Pick)

    /// "Share api-service securely" for one repository or folder; "Share Securely" otherwise.
    static func title(_ name: String?) -> String {
        guard let name else {
            return String(localized: "projectShare.title.securely", defaultValue: "Share Securely")
        }
        return String(localized: "projectShare.title.named", defaultValue: "Share \(name) securely")
    }

    static let subtitle = String(
        localized: "projectShare.subtitle.passphrase",
        defaultValue: "An encrypted file, opened with a passphrase you send another way."
    )
    static let repositories = String(localized: "projectShare.repositories", defaultValue: "Repositories")
    static let addRepository = String(localized: "projectShare.addRepository", defaultValue: "Add Repository")
    static let removeRepository = String(localized: "projectShare.removeRepository", defaultValue: "Remove from the file")
    static let noRepositories = String(
        localized: "projectShare.noRepositories",
        defaultValue: "No repository chosen. Add one, or share folders only."
    )
    static let stages = String(localized: "projectShare.stages", defaultValue: "Stages")
    static let stagesHelp = String(
        localized: "projectShare.stages.help",
        defaultValue: "A stage includes the GitHub environment with its name and the destinations of that stage, in every repository above."
    )
    static let noStages = String(
        localized: "projectShare.noStages",
        defaultValue: "These repositories have no environments or destinations with a stage."
    )
    /// The tag beside a production stage or environment.
    static let productionTag = String(localized: "projectShare.productionTag", defaultValue: "production")
    static let productionHelp = String(
        localized: "projectShare.production.help",
        defaultValue: "Unchecked by default. Checking it asks for Touch ID."
    )
    /// A production environment ticked in the tree is confirmed when the file is created.
    static let productionTreeHelp = String(
        localized: "projectShare.production.treeHelp",
        defaultValue: "Creating a file with production asks for Touch ID or your master password."
    )
    static let back = String(localized: "projectShare.back", defaultValue: "Back")

    static func valueMissing(_ count: Int) -> String {
        count == 1
            ? String(localized: "projectShare.valueMissing.one", defaultValue: "1 secret has no value here and travels by name only")
            : String(localized: "projectShare.valueMissing", defaultValue: "\(count) secrets have no value here and travel by name only")
    }

    /// The note under the tree when a checked folder keeps files (v23).
    static let folderFilesLeftOut = String(
        localized: "projectShare.folderFiles.leftOut",
        defaultValue: "Files kept in folders aren't included. Send them another way if your teammate needs them."
    )

    /// The note under the tree when the file carries production values.
    static func productionIncluded(_ places: [String]) -> String {
        String(
            localized: "projectShare.production.leaves",
            defaultValue: "Production values leave this Mac in a file (\(places.joined(separator: ", "))). Rotate them if it leaks."
        )
    }

    static let expiry = String(localized: "projectShare.expiry", defaultValue: "Expires after")

    static func expiryChoice(_ choice: ShareExpiryChoice) -> String {
        choice.days == 1
            ? String(localized: "projectShare.expiry.day.one", defaultValue: "1 day")
            : String(localized: "projectShare.expiry.days", defaultValue: "\(choice.days) days")
    }

    /// "13 secrets · 6 variables"; a kind with none is left out, and nothing is "".
    static func counts(_ counts: ShareItemCountModel) -> String {
        PlaceCopy.counts(secrets: counts.secrets, variables: counts.variables, omitsZeroKinds: true)
    }

    static let createFile = String(localized: "projectShare.createFile", defaultValue: "Create File")
    static let createFileWithTouchID = String(localized: "projectShare.createFile.touchID", defaultValue: "Create File with Touch ID")
    static let reauthMessage = String(
        localized: "projectShare.reauth.message",
        defaultValue: "Sharing exports values. Use Touch ID or your master password to continue."
    )
    static let productionReauthMessage = String(
        localized: "projectShare.reauth.production",
        defaultValue: "This file includes production values. Use Touch ID or your master password to continue."
    )
    static let creating = String(localized: "projectShare.creating", defaultValue: "Encrypting the share…")

    // MARK: - Done (board Share-Passphrase)

    static let doneTitle = String(localized: "projectShare.done.title", defaultValue: "Send the passphrase another way")
    static let sendApart = String(
        localized: "projectShare.done.sendApart",
        defaultValue: "Send the file by chat or AirDrop, and the words by call or another app."
    )

    static func clipboardClears(_ seconds: Int) -> String {
        String(localized: "projectShare.done.clipboardClears", defaultValue: "The clipboard clears in \(seconds) s.")
    }

    static func copied(_ seconds: Int) -> String {
        String(localized: "projectShare.done.copied", defaultValue: "Copied. The clipboard clears in \(seconds) s.")
    }

    /// The finished file's footer: "FX Vault refuses it after 1 Nov, 14:02. Rotate anything in it if it leaks."
    static func refusedAfter(_ date: Date) -> String {
        String(
            localized: "projectShare.done.refusedAfter.time",
            defaultValue: "FX Vault refuses it after \(moment(date)). Rotate anything in it if it leaks."
        )
    }

    /// A day and time as the share sheets and Settings › Sharing write them: "1 Nov, 14:02" in
    /// the user's locale (a file expires at the minute it was created, days later).
    static func moment(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    static let share = String(localized: "projectShare.share", defaultValue: "Share…")
    static let airDrop = String(localized: "projectShare.airDrop", defaultValue: "Send with AirDrop")
    static let saveFile = String(localized: "projectShare.saveFile", defaultValue: "Save File…")

    static func saved(_ name: String) -> String {
        String(localized: "projectShare.saved.passphrase", defaultValue: "Saved “\(name)”. Send the passphrase separately.")
    }

    static let sent = String(localized: "projectShare.sent.passphrase", defaultValue: "File sent. Send the passphrase through a different app.")

    // MARK: - Opening a file (boards Share-Open, Share-OpenPreview, Share-Expired)

    /// "Open FX Vault share 25 Oct.fxvault".
    static func openTitle(_ fileName: String) -> String {
        String(localized: "projectShare.open.title", defaultValue: "Open \(fileName)")
    }

    static let passphraseLabel = String(
        localized: "projectShare.open.passphraseLabel",
        defaultValue: "\(Limits.passphraseWordCount)-word passphrase"
    )
    static let passphrasePrompt = String(
        localized: "projectShare.open.passphrasePrompt",
        defaultValue: "six words separated by spaces"
    )

    static func from(_ sender: String) -> String {
        sender.isEmpty
            ? String(localized: "projectShare.open.fromUnknown", defaultValue: "From an unknown sender")
            : String(localized: "projectShare.open.from", defaultValue: "From \(sender)")
    }

    static let unverified = String(localized: "projectShare.open.unverified", defaultValue: "Not verified")
    static let unverifiedHelp = String(
        localized: "projectShare.open.unverified.help",
        defaultValue: "A share file says who sent it but can't prove it."
    )

    /// "Unlocked · created 25 Oct, 14:02 · expires 1 Nov, 14:02".
    static func unlocked(created: Date, expires: Date) -> String {
        String(
            localized: "projectShare.open.unlocked.time",
            defaultValue: "Unlocked · created \(moment(created)) · expires \(moment(expires))"
        )
    }

    static let whatItAdds = String(localized: "projectShare.open.whatItAdds", defaultValue: "What it adds · nothing is deleted")
    static let nothingSyncs = String(
        localized: "projectShare.open.nothingSyncs.azure",
        defaultValue: "Nothing reaches GitHub or Azure until you include it in Sync."
    )
    static let importAsHeld = String(localized: "projectShare.open.importAsHeld", defaultValue: "Import as Held")
    static let inVault = String(localized: "projectShare.open.alreadyInVault", defaultValue: "Already in your vault")

    static func willImport(_ account: String?) -> String {
        guard let account, !account.isEmpty else {
            return String(localized: "projectShare.open.newRepository", defaultValue: "New repository · import from GitHub")
        }
        return String(
            localized: "projectShare.open.newRepositoryWith",
            defaultValue: "New repository · import from GitHub with \(account)"
        )
    }

    static func skipped(_ reason: ShareRepositoryNoAccessReason) -> String {
        switch reason {
        case .notVisible:
            String(localized: "projectShare.open.skipped.noAccess", defaultValue: "Skipped · no access")
        case .unreachable:
            String(localized: "projectShare.open.skipped.offline", defaultValue: "Skipped · GitHub unreachable")
        case .notChecked:
            String(localized: "projectShare.open.skipped.unchecked", defaultValue: "Skipped · access not checked")
        }
    }

    static let skippedLater = String(
        localized: "projectShare.open.skipped.later",
        defaultValue: "Open the same file again once you have access to import it."
    )
    static let destinations = String(localized: "projectShare.open.destinations", defaultValue: "Destinations")
    static let newDestination = String(
        localized: "projectShare.open.destination.new",
        defaultValue: "New. FX Vault reaches it with your az login."
    )
    static let mergedDestination = String(
        localized: "projectShare.open.destination.merge",
        defaultValue: "Merges into your destination with the same target."
    )

    /// Supabase and Vercel destinations a 0.9 file still carries; 1.0 imports it without them.
    static func retiredDestinations(_ labels: [String]) -> String {
        String(
            localized: "projectShare.open.destinations.retired",
            defaultValue: "Left out: \(labels.joined(separator: ", ")). Supabase and Vercel are no longer supported."
        )
    }

    static let folders = String(localized: "projectShare.open.folders", defaultValue: "Folders")
    static let newFolder = String(localized: "projectShare.open.folder.new", defaultValue: "New folder")
    static let mergeFolderKeep = String(localized: "projectShare.open.folder.mergeKeep", defaultValue: "Merge, keep mine")
    static let mergeFolderReplace = String(localized: "projectShare.open.folder.mergeReplace", defaultValue: "Merge, replace mine")
    static let skipFolder = String(localized: "projectShare.open.folder.skip", defaultValue: "Don't import")
    static let importing = String(localized: "projectShare.open.importing", defaultValue: "Importing repositories from GitHub…")

    static func importFailed(_ names: [String]) -> String {
        String(
            localized: "projectShare.open.importFailed",
            defaultValue: "Couldn't import \(names.joined(separator: ", ")) from GitHub. It was skipped."
        )
    }

    // MARK: - Result

    static func doneRepositories(_ count: Int) -> String {
        count == 1
            ? String(localized: "projectShare.done.repository.one", defaultValue: "1 repository updated")
            : String(localized: "projectShare.done.repositories", defaultValue: "\(count) repositories updated")
    }

    static func doneDestinations(_ count: Int) -> String {
        count == 1
            ? String(localized: "projectShare.done.destination.one", defaultValue: "1 destination added")
            : String(localized: "projectShare.done.destinations", defaultValue: "\(count) destinations added")
    }

    static func doneDestinationItems(_ count: Int) -> String {
        count == 1
            ? String(localized: "projectShare.done.destinationItem.one", defaultValue: "1 destination value written")
            : String(localized: "projectShare.done.destinationItems", defaultValue: "\(count) destination values written")
    }

    static func doneFolders(_ count: Int) -> String {
        count == 1
            ? String(localized: "projectShare.done.folder.one", defaultValue: "1 folder saved")
            : String(localized: "projectShare.done.folders", defaultValue: "\(count) folders saved")
    }

    static func doneHeld(_ count: Int) -> String {
        count == 1
            ? String(localized: "projectShare.done.held.one", defaultValue: "1 change waits for you in Sync › From Files")
            : String(localized: "projectShare.done.held", defaultValue: "\(count) changes wait for you in Sync › From Files")
    }

    static func doneLinks(_ count: Int) -> String {
        count == 1
            ? String(localized: "projectShare.done.link.one", defaultValue: "1 group of linked copies kept")
            : String(localized: "projectShare.done.links", defaultValue: "\(count) groups of linked copies kept")
    }

    static let doneNothing = String(localized: "projectShare.done.nothing", defaultValue: "Nothing changed.")

    // MARK: - Settings › Sharing

    static let settingsTab = String(localized: "settings.sharing.tab", defaultValue: "Sharing")
    static let settingsTitle = String(localized: "settings.sharing.shared", defaultValue: "Files you shared")
    static let settingsFootnote = String(
        localized: "settings.sharing.footnote",
        defaultValue: "Names only; FX Vault keeps no copy of the file. If one leaks, rotate what’s in it."
    )
    static let settingsEmpty = String(localized: "settings.sharing.empty", defaultValue: "No share files sent from this Mac yet.")
    static let active = String(localized: "settings.sharing.active", defaultValue: "Active")
    static let expired = String(localized: "settings.sharing.expired", defaultValue: "Expired")

    /// "expires 1 Nov, 14:02", or "expired 10 Oct, 09:30" once it has.
    static func sentExpiry(_ date: Date, isExpired: Bool) -> String {
        isExpired
            ? String(localized: "settings.sharing.expiredOn", defaultValue: "expired \(moment(date))")
            : String(localized: "settings.sharing.expiresOn", defaultValue: "expires \(moment(date))")
    }

    static func teammatesMode(_ names: [String]) -> String {
        String(localized: "settings.sharing.mode.teammates", defaultValue: "Teammates: \(names.joined(separator: ", "))")
    }

    static let showNames = String(localized: "settings.sharing.showNames", defaultValue: "Show names")
    static let hideNames = String(localized: "settings.sharing.hideNames", defaultValue: "Hide names")
    static let removeEntry = String(localized: "settings.sharing.remove", defaultValue: "Remove from List")
    static let removeEntryHelp = String(
        localized: "settings.sharing.remove.help",
        defaultValue: "Removes this entry only. The file you sent isn't affected."
    )
    static let repositoryLevelPlace = String(localized: "settings.sharing.place.repository", defaultValue: "Repository level")

    static func unknownTeammate(_ id: String) -> String {
        String(localized: "settings.sharing.unknownTeammate", defaultValue: "Removed teammate \(id.prefix(Self.deviceIDPrefixLength))")
    }

    /// How much of a device id names a teammate that is no longer paired.
    private static let deviceIDPrefixLength = 6
}
