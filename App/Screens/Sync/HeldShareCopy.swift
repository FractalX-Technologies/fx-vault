import Foundation
import VaultCore

/// Text of the rows held by share files (v0.9.0, tasks/todo.md P8): Sync's From Files review,
/// the Held chip in the tables and the notices after releasing a hold. Names and counts only.
enum HeldShareCopy {
    // MARK: From Files review

    static var sectionTitle: String {
        String(localized: "sync.held.title", defaultValue: "From Files")
    }

    static var explanation: String {
        String(
            localized: "sync.held.explanation",
            defaultValue: "Imported from a share file. Nothing from it reaches GitHub or a provider until you include it."
        )
    }

    static var include: String {
        String(localized: "sync.held.include", defaultValue: "Include in this Sync")
    }

    /// "From Ana's file"; a file without a sender name: "From a share file".
    static func fileTitle(sender: String?) -> String {
        guard let sender, !sender.isEmpty else {
            return String(localized: "sync.held.file.unnamed", defaultValue: "From a share file")
        }
        return String(localized: "sync.held.file.named", defaultValue: "From \(sender)'s file")
    }

    static var verified: String {
        String(localized: "sync.held.verified", defaultValue: "Verified")
    }

    static var verifiedHelp: String {
        String(
            localized: "sync.held.verified.help",
            defaultValue: "Sealed for your Mac by a teammate: FX Vault checked their signature when the file was opened."
        )
    }

    static var unverified: String {
        String(localized: "sync.held.unverified", defaultValue: "Unverified")
    }

    static var unverifiedHelp: String {
        String(
            localized: "sync.held.unverified.help",
            defaultValue: "Opened with a passphrase: the sender's name is what the file says. FX Vault can't check it."
        )
    }

    /// "Imported 17 Oct 2026 · 3 items".
    static func meta(importedAt: Date?, itemCount: Int) -> String {
        let items = itemCount == 1
            ? String(localized: "sync.held.items.one", defaultValue: "1 item")
            : String(localized: "sync.held.items", defaultValue: "\(itemCount) items")
        guard let importedAt else { return items }
        let date = importedAt.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "sync.held.meta", defaultValue: "Imported \(date) · \(items)")
    }

    /// "Show 3 items" / "Hide items".
    static func disclosure(isExpanded: Bool, itemCount: Int) -> String {
        if isExpanded {
            return String(localized: "sync.held.hide", defaultValue: "Hide Items")
        }
        return itemCount == 1
            ? String(localized: "sync.held.show.one", defaultValue: "Show 1 Item")
            : String(localized: "sync.held.show", defaultValue: "Show \(itemCount) Items")
    }

    /// The environment's creation waits for the file too.
    static func createsEnvironment(_ name: String) -> String {
        String(localized: "sync.held.createsEnvironment", defaultValue: "Also creates or renames environment \(name)")
    }

    /// The summary banner when every pending change waits for a share file.
    static var onlyHeld: String {
        String(
            localized: "sync.held.onlyHeld",
            defaultValue: "Only rows from share files are waiting. Include a file below to sync it."
        )
    }

    // MARK: Tables

    static var chip: String {
        String(localized: "main.table.held", defaultValue: "Held")
    }

    /// The Held chip's tooltip.
    static func chipHelp(sender: String?) -> String {
        guard let sender, !sender.isEmpty else {
            return String(
                localized: "main.table.held.help.unnamed",
                defaultValue: "Imported from a share file. It reaches GitHub or the provider only when you include the file in Sync's From Files review, or choose Push on Next Sync."
            )
        }
        return String(
            localized: "main.table.held.help",
            defaultValue: "Imported from \(sender)'s share file. It reaches GitHub or the provider only when you include the file in Sync's From Files review, or choose Push on Next Sync."
        )
    }

    /// After Push on Next Sync released held rows.
    static func released(name: String?, count: Int) -> String {
        if count == 1, let name {
            return String(
                localized: "main.table.held.released.one",
                defaultValue: "The next Sync pushes \(name). It is no longer held."
            )
        }
        return count == 1
            ? String(localized: "main.table.held.released.oneUnnamed", defaultValue: "The next Sync pushes 1 item. It is no longer held.")
            : String(localized: "main.table.held.released", defaultValue: "The next Sync pushes \(count) items. They are no longer held.")
    }
}
