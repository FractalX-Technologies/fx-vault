import Foundation

/// The jump palette's texts (1.0 D6c2; board Main2-Search).
enum JumpPaletteCopy {
    static let title = String(localized: "jump.title", defaultValue: "Jump to")
    static let prompt = String(localized: "jump.prompt", defaultValue: "Jump to a place")
    static let places = String(localized: "jump.places", defaultValue: "Places")
    static let noMatches = String(localized: "jump.noMatches", defaultValue: "No places match")
    static let move = String(localized: "jump.footer.move", defaultValue: "to move")
    static let open = String(localized: "jump.footer.open", defaultValue: "to open")
    static let close = String(localized: "jump.footer.close", defaultValue: "to close")
    /// The toolbar button and the menu command.
    static let jumpAnywhere = String(localized: "jump.anywhere", defaultValue: "Jump Anywhere")
    static let jumpAnywhereHelp = String(localized: "jump.anywhere.help", defaultValue: "Jump to a place (⌘K)")
    /// After a `KeyHint("⌘K")` on the home (board Main2-Home).
    static let toJumpAnywhere = String(localized: "jump.anywhere.hint", defaultValue: "to jump anywhere")

    static let organization = String(localized: "jump.place.organization", defaultValue: "GitHub organization")

    static func repository(owner: String) -> String {
        String(localized: "jump.place.repository", defaultValue: "\(owner) › repository")
    }

    static func environment(owner: String, repository: String) -> String {
        String(localized: "jump.place.environment", defaultValue: "\(owner) › \(repository) › environment")
    }
}
