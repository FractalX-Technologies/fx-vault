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
        defaultValue: "The value shows for \(Timeouts.revealRemask.wholeSeconds) seconds, then hides again."
    )

    static let revealAll = String(localized: "notes.revealAll", defaultValue: "Reveal All")
    static let hideAll = String(localized: "notes.revealAll.hide", defaultValue: "Hide All")

    static let revealAllHelp = String(
        localized: "notes.revealAll.help",
        defaultValue: "Reveal every secret here for \(Timeouts.revealAllRemask.wholeSeconds) seconds; click a line to copy its value. Asks for Touch ID or your master password."
    )

    static let revealAllTitle = String(localized: "notes.revealAll.title", defaultValue: "Reveal All Secrets")

    static func revealAllMessage(place: String) -> String {
        String(
            localized: "notes.revealAll.message",
            defaultValue: "Every secret of \(place) shows for \(Timeouts.revealAllRemask.wholeSeconds) seconds, then hides again. Click a line to copy its value."
        )
    }

    static let clickToCopy = String(localized: "notes.revealAll.clickToCopy", defaultValue: "Click a line to copy its value")

    /// "Confirm it's you" before a secret's Copy (the table, 1.0 T1; the quick vault, Q1).
    static func copy(_ name: String) -> String {
        String(localized: "quickVault.copy", defaultValue: "Copy \(name)")
    }

    static let copyMessage = String(
        localized: "quickVault.copy.message",
        defaultValue: "The value goes to the clipboard, which clears in \(Timeouts.clipboardClear.wholeSeconds) seconds."
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
