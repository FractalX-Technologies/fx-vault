import Foundation

/// The edits the notes editor refuses (1.0 N2): a section's `# Secrets` and `# Variables` lines
/// stay whole and at the start of a line, so every line always has a section.
enum NotesEditGuard {
    static let lineBreak = unichar(0x0A)

    /// True when replacing `range` of `text` with `replacement` keeps every heading in `headings`
    /// (their ranges, without the line break) whole and first on its line.
    static func allows(_ range: NSRange, replacement: String, in text: NSString, headings: [NSRange]) -> Bool {
        headings.allSatisfy { heading in
            allows(range, replacement: replacement, in: text, heading: heading)
        }
    }

    private static func allows(_ range: NSRange, replacement: String, in text: NSString, heading: NSRange) -> Bool {
        let end = NSMaxRange(heading)
        // The heading's characters and the line break after it.
        let protected = NSRange(location: heading.location, length: min(heading.length + 1, text.length - heading.location))
        if range.length > 0, NSIntersectionRange(range, protected).length > 0 {
            return false
        }
        if range.length == 0, (heading.location...end).contains(range.location) {
            // Only Return at the end of the heading: it opens a line under it.
            return range.location == end && replacement == "\n"
        }
        // Deleting up to the heading would join it to the text before it.
        let joinsPreviousLine = range.length > 0 && NSMaxRange(range) == heading.location && range.location > 0
            && text.character(at: range.location - 1) != lineBreak
        return !joinsPreviousLine || replacement.hasSuffix("\n")
    }
}
