import Foundation
import VaultCore

/// The texts of Copy All (1.0 D6c4; boards Main2-Repository, Main2-Actions): the header button,
/// the ⋯ item, the confirmation sheet and the section titles of the copied text.
nonisolated enum CopyAllCopy {
    static let title = String(localized: "copyAll.title", defaultValue: "Copy All")
    // The fingerprint glyph says it visually; VoiceOver hears it (board aria-label).
    static let accessibilityLabel = String(localized: "copyAll.accessibility", defaultValue: "Copy All, asks for Touch ID")
    static let help = String(
        localized: "copyAll.help",
        defaultValue: "Copy every value of this place as .env text. Asks for Touch ID or your master password."
    )
    static let message = String(
        localized: "copyAll.message",
        defaultValue: "Every value of this place goes to the clipboard as .env text, in plain text, until the clipboard clears."
    )
    static let doneTitle = String(localized: "copyAll.done.title", defaultValue: "Copied")

    /// "8 values copied as .env text. The clipboard clears in 30 seconds."
    static func doneMessage(count: Int, seconds: Int) -> String {
        String(inflected: AttributedString(
            localized: "copyAll.done.message",
            defaultValue: "^[\(count) value](inflect: true) copied as .env text. The clipboard clears in \(seconds) seconds."
        ))
    }

    /// The `# ` heading of each kind in the copied text (board Main2-Repository: "Secrets · 6").
    static func section(_ kind: ConfigKind, count: Int) -> String {
        switch kind {
        case .secret: String(localized: "copyAll.section.secrets", defaultValue: "Secrets · \(count)")
        case .variable: String(localized: "copyAll.section.variables", defaultValue: "Variables · \(count)")
        }
    }
}
