import Foundation
import VaultCore

/// The texts of a place's notes (1.0 B9; boards Main2-Repository, Place-Reveal, KV-Place).
nonisolated enum NotesCopy {
    static let notes = String(localized: "notes.mode.notes", defaultValue: "Notes")
    static let table = String(localized: "notes.mode.table", defaultValue: "Table")
    static let viewMode = String(localized: "notes.mode.label", defaultValue: "View")

    /// A masked value's token. Four dots whatever the value, so the mask tells nothing.
    static let maskToken = "••••"

    /// A section's line as the notes show it: `# Secrets · 6`.
    static func heading(_ title: String) -> String {
        "# \(title)"
    }

    /// "From example-org · 5 · read only": the organization items a repository gets.
    static func inheritedSection(organization: String, count: Int) -> String {
        String(localized: "notes.section.inherited", defaultValue: "From \(organization) · \(count) · read only")
    }

    static let noValue = String(localized: "notes.note.noValue", defaultValue: "no value")

    static func overrides(_ organization: String) -> String {
        String(localized: "notes.note.overrides", defaultValue: "overrides \(organization)")
    }

    static let pendingMark = String(localized: "notes.mark.pending", defaultValue: "Waits for the next Sync")

    static func accessibilityLabel(place: String) -> String {
        String(localized: "notes.accessibility", defaultValue: "\(place) notes")
    }

    static func reveal(_ name: String) -> String {
        String(localized: "notes.reveal", defaultValue: "Reveal \(name)")
    }

    static let revealHelp = String(
        localized: "notes.reveal.help",
        defaultValue: "Reveal this value for \(Timeouts.revealRemask.wholeSeconds) seconds. Asks for Touch ID or your master password."
    )

    static let revealMessage = String(
        localized: "notes.reveal.message",
        defaultValue: "The value shows in the notes for \(Timeouts.revealRemask.wholeSeconds) seconds, then hides again."
    )

    /// "hides in 30 s" beside a revealed value (board Place-Reveal).
    static func hidesIn(seconds: Int) -> String {
        String(localized: "notes.reveal.hidesIn", defaultValue: "hides in \(seconds) s")
    }

    static func hidesInAccessibility(seconds: Int) -> String {
        String(localized: "notes.reveal.hidesIn.accessibility", defaultValue: "Hides in \(seconds) seconds")
    }

    static let hide = String(localized: "notes.reveal.hide", defaultValue: "Hide")

    /// The toolbar's mark while a value shows (board Place-Reveal).
    static let hiddenFromCapture = String(localized: "notes.hiddenFromCapture", defaultValue: "Hidden from screen capture")
}
