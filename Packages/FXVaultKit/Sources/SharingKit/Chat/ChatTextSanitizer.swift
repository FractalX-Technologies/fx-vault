import Foundation
import VaultCore

/// Cleans chat text for display, on both sides (Trojan Source and invisible-text defense).
///
/// - Line breaks: CR LF, CR, U+2028 and U+2029 become LF; LF and TAB are kept.
/// - Removed: every other control character (C0, DEL, C1), every bidi formatting character, the
///   zero-width characters of ``UnicodeScalarPolicy`` and every other invisible character
///   (``UnicodeScalarPolicy/isInvisible(_:)``: format characters such as tag characters, soft
///   hyphens and invisible operators, Hangul fillers), except U+200D ZERO WIDTH JOINER, which
///   emoji sequences need.
/// - Then NFC; at most ``Limits/chatMaxBlankLines`` blank lines in a row are kept and at most
///   ``Limits/chatMaxMarksPerCharacter`` combining marks per character (a wall of empty lines
///   or stacked marks must not push other messages off screen); leading and trailing
///   whitespace and newlines are trimmed.
///
/// Never throws; the result may be empty.
public enum ChatTextSanitizer {
    private static let lineFeed: Unicode.Scalar = "\n"
    private static let tab: Unicode.Scalar = "\t"
    private static let carriageReturn: Unicode.Scalar = "\r"
    private static let lineSeparator: Unicode.Scalar = "\u{2028}"
    private static let paragraphSeparator: Unicode.Scalar = "\u{2029}"
    private static let zeroWidthJoiner: Unicode.Scalar = "\u{200D}"

    /// The text as it may be shown.
    public static func sanitize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var previousWasCarriageReturn = false
        for scalar in text.unicodeScalars {
            defer { previousWasCarriageReturn = scalar == carriageReturn }
            switch scalar {
            case lineFeed:
                // CR LF: the CR already produced the line feed.
                if !previousWasCarriageReturn { scalars.append(lineFeed) }
            case carriageReturn, lineSeparator, paragraphSeparator:
                scalars.append(lineFeed)
            case tab, zeroWidthJoiner:
                scalars.append(scalar)
            default:
                if UnicodeScalarPolicy.violation(of: scalar) == nil, !UnicodeScalarPolicy.isInvisible(scalar) {
                    scalars.append(scalar)
                }
            }
        }
        return limitingLayout(String(scalars).precomposedStringWithCanonicalMapping)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops blank lines beyond ``Limits/chatMaxBlankLines`` in a row and combining marks beyond
    /// ``Limits/chatMaxMarksPerCharacter`` on one character.
    private static func limitingLayout(_ text: String) -> String {
        var lines: [String] = []
        var blankRun = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.allSatisfy(\.isWhitespace) {
                blankRun += 1
                guard blankRun <= Limits.chatMaxBlankLines else { continue }
            } else {
                blankRun = 0
            }
            lines.append(String(line.map(cappingMarks).joined()))
        }
        return lines.joined(separator: "\n")
    }

    private static func cappingMarks(_ character: Character) -> String {
        var marks = 0
        var scalars = String.UnicodeScalarView()
        for scalar in character.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .enclosingMark:
                marks += 1
                if marks > Limits.chatMaxMarksPerCharacter { continue }
            default:
                break
            }
            scalars.append(scalar)
        }
        return String(scalars)
    }
}
