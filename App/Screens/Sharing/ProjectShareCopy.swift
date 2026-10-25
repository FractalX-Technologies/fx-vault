import Foundation
import SharingKit
import VaultCore
import VaultData

/// Text of the project share sheets (v0.9.0): Share Project, the bundle preview of Import Share
/// and Settings › Sharing. Every count has a singular variant (lessons, 2026-10-16).
enum ProjectShareCopy {
    // MARK: - Share sheet

    static let title = String(localized: "projectShare.title", defaultValue: "Share Project")
    static let subtitle = String(
        localized: "projectShare.subtitle",
        defaultValue: "One encrypted .fxvault file with the repositories, stages and destinations you choose."
    )
    static let shareStage = String(localized: "projectShare.shareStage", defaultValue: "Share Stage…")
    static let shareStageHelp = String(
        localized: "projectShare.shareStage.help",
        defaultValue: "Share this stage's GitHub environment and destinations in an encrypted file."
    )
    static let contentsStep = String(localized: "projectShare.step.contents", defaultValue: "What to share")
    static let sendToStep = String(localized: "projectShare.step.sendTo", defaultValue: "Send to")
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
    static let productionChip = String(localized: "projectShare.production", defaultValue: "Production")
    static let productionHelp = String(
        localized: "projectShare.production.help",
        defaultValue: "Production is never shared. Teammates get production values from your secret store."
    )
    static let repositoryLevel = String(
        localized: "projectShare.repositoryLevel",
        defaultValue: "Repository-level secrets and variables"
    )
    static let adjust = String(localized: "projectShare.adjust", defaultValue: "Adjust what's included")
    static let continueTitle = String(localized: "projectShare.continue", defaultValue: "Continue")
    static let back = String(localized: "projectShare.back", defaultValue: "Back")

    static func summary(_ preview: ShareBundleExportPreviewModel) -> String {
        let repositories = preview.summary.repositories.count
        let folders = preview.summary.folders.count
        let items = preview.itemCount
        let itemText = items == 1
            ? String(localized: "projectShare.summary.item.one", defaultValue: "1 secret or variable")
            : String(localized: "projectShare.summary.items", defaultValue: "\(items) secrets and variables")
        let repositoryText = repositories == 1
            ? String(localized: "projectShare.summary.repository.one", defaultValue: "1 repository")
            : String(localized: "projectShare.summary.repositories", defaultValue: "\(repositories) repositories")
        guard folders > 0 else {
            return String(localized: "projectShare.summary.line", defaultValue: "\(itemText) in \(repositoryText)")
        }
        let folderText = folders == 1
            ? String(localized: "projectShare.summary.folder.one", defaultValue: "1 folder")
            : String(localized: "projectShare.summary.folders", defaultValue: "\(folders) folders")
        guard repositories > 0 else {
            return String(localized: "projectShare.summary.lineFolders", defaultValue: "\(itemText) in \(folderText)")
        }
        return String(
            localized: "projectShare.summary.lineBoth",
            defaultValue: "\(itemText) in \(repositoryText) and \(folderText)"
        )
    }

    static func valueMissing(_ count: Int) -> String {
        count == 1
            ? String(localized: "projectShare.valueMissing.one", defaultValue: "1 secret has no value here and travels by name only")
            : String(localized: "projectShare.valueMissing", defaultValue: "\(count) secrets have no value here and travel by name only")
    }

    // MARK: - Send to

    static let passphraseOption = String(localized: "projectShare.protection.passphrase", defaultValue: "Anyone, with a passphrase")
    static let passphraseHelp = String(
        localized: "projectShare.protection.passphrase.help",
        defaultValue: "Six words that you send another way. Whoever has the file and the words can open it."
    )

    static func productionBlocked(_ places: [String]) -> String {
        String(
            localized: "projectShare.production.blocked",
            defaultValue: "Can't be shared: the file includes production (\(places.joined(separator: ", "))). Uncheck it to continue."
        )
    }

    static let expiry = String(localized: "projectShare.expiry", defaultValue: "Expires after")

    static func expiryChoice(_ choice: ShareExpiryChoice) -> String {
        choice.days == 1
            ? String(localized: "projectShare.expiry.day.one", defaultValue: "1 day")
            : String(localized: "projectShare.expiry.days", defaultValue: "\(choice.days) days")
    }

    static let expiryPassphraseNote = String(
        localized: "projectShare.expiry.passphrase",
        defaultValue: "FX Vault refuses to open it after this date. Anyone with the passphrase could still read it with other software."
    )
    static let create = String(localized: "projectShare.create", defaultValue: "Create Share File")
    static let reauthMessage = String(
        localized: "projectShare.reauth.message",
        defaultValue: "Sharing exports values. Use Touch ID or your master password to continue."
    )
    static let creating = String(localized: "projectShare.creating", defaultValue: "Encrypting the share…")

    // MARK: - Done

    static let passphraseHint = String(
        localized: "projectShare.done.passphraseHint",
        defaultValue: "Send these words another way (a call or another app), not with the file."
    )

    static func expires(_ date: Date) -> String {
        String(localized: "projectShare.expires", defaultValue: "Expires \(date.formatted(date: .abbreviated, time: .shortened))")
    }

    static let share = String(localized: "projectShare.share", defaultValue: "Share…")
    static let save = String(localized: "projectShare.save", defaultValue: "Save…")

    static func saved(_ name: String) -> String {
        String(localized: "projectShare.saved.passphrase", defaultValue: "Saved “\(name)”. Send the passphrase separately.")
    }

    static let sent = String(localized: "projectShare.sent.passphrase", defaultValue: "File sent. Send the passphrase through a different app.")

    // MARK: - Opening a bundle

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

    static func dates(created: Date, expires: Date) -> String {
        String(
            localized: "projectShare.open.dates",
            defaultValue: "Created \(created.formatted(date: .abbreviated, time: .shortened)) · Expires \(expires.formatted(date: .abbreviated, time: .shortened))"
        )
    }

    static let nothingSyncs = String(
        localized: "projectShare.open.nothingSyncs",
        defaultValue: "Nothing reaches GitHub or a provider until you include it in Sync."
    )
    static let inVault = String(localized: "projectShare.open.inVault", defaultValue: "In your vault")

    static func willImport(_ account: String?) -> String {
        guard let account, !account.isEmpty else {
            return String(localized: "projectShare.open.willImport", defaultValue: "Will be imported from GitHub")
        }
        return String(localized: "projectShare.open.willImportWith", defaultValue: "Will be imported from GitHub with \(account)")
    }

    static func skipped(_ reason: ShareRepositoryNoAccessReason) -> String {
        switch reason {
        case .notVisible:
            String(localized: "projectShare.open.skipped.notVisible", defaultValue: "Skipped: none of your GitHub accounts can see it")
        case .unreachable:
            String(localized: "projectShare.open.skipped.unreachable", defaultValue: "Skipped: GitHub couldn't be reached to check access")
        case .notChecked:
            String(localized: "projectShare.open.skipped.notChecked", defaultValue: "Skipped: access couldn't be checked")
        }
    }

    static let skippedLater = String(
        localized: "projectShare.open.skipped.later",
        defaultValue: "Open the same file again once you have access to import it."
    )
    static let destinations = String(localized: "projectShare.open.destinations", defaultValue: "Destinations")
    static let newDestination = String(
        localized: "projectShare.open.destination.new",
        defaultValue: "New, without a connection. Connect your account in Settings › Destinations."
    )
    static let mergedDestination = String(
        localized: "projectShare.open.destination.merge",
        defaultValue: "Merges into your destination with the same target."
    )
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

    static func changes(_ count: Int) -> String {
        count == 1
            ? String(localized: "projectShare.open.change.one", defaultValue: "1 change")
            : String(localized: "projectShare.open.changes", defaultValue: "\(count) changes")
    }

    static func repositoryCount(_ count: Int) -> String {
        count == 1
            ? String(localized: "projectShare.open.repository.one", defaultValue: "1 repository")
            : String(localized: "projectShare.open.repositories", defaultValue: "\(count) repositories")
    }

    // MARK: - Result

    static func doneRepositories(_ count: Int) -> String {
        count == 1
            ? String(localized: "projectShare.done.repository.one", defaultValue: "1 repository updated")
            : String(localized: "projectShare.done.repositories", defaultValue: "\(count) repositories updated")
    }

    static func doneDestinations(_ count: Int) -> String {
        count == 1
            ? String(localized: "projectShare.done.destination.one", defaultValue: "1 destination added without a connection")
            : String(localized: "projectShare.done.destinations", defaultValue: "\(count) destinations added without a connection")
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
    static let settingsTitle = String(localized: "settings.sharing.title", defaultValue: "Files you sent")
    static let settingsHelp = String(
        localized: "settings.sharing.help",
        defaultValue: "Every share file this Mac wrote, with the names it carried. Values are never kept here."
    )
    static let settingsEmpty = String(localized: "settings.sharing.empty", defaultValue: "No share files sent from this Mac yet.")
    static let expired = String(localized: "settings.sharing.expired", defaultValue: "Expired")
    static let passphraseMode = String(localized: "settings.sharing.mode.passphrase", defaultValue: "Passphrase")

    static func teammatesMode(_ names: [String]) -> String {
        String(localized: "settings.sharing.mode.teammates", defaultValue: "Teammates: \(names.joined(separator: ", "))")
    }

    static func secretNames(_ count: Int) -> String {
        count == 1
            ? String(localized: "settings.sharing.secrets.one", defaultValue: "1 secret")
            : String(localized: "settings.sharing.secrets", defaultValue: "\(count) secrets")
    }

    static let namesInFile = String(localized: "settings.sharing.names", defaultValue: "Names in this file")
    static let rotateHint = String(localized: "settings.sharing.rotate", defaultValue: "Rotate these secrets if the file leaked.")
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
