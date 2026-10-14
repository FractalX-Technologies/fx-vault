import Foundation

/// Cleans a display name shown to another person (nearby HELLO, share sender, §9.3–§9.4).
///
/// Never throws: it removes control, bidi and zero-width characters, normalizes to NFC, trims
/// whitespace and truncates to at most `maxBytes` UTF-8 bytes on a character boundary. The
/// result may be empty; callers substitute their own fallback.
public enum DisplayNameSanitizer {
    /// The sanitized name.
    public static func sanitize(
        _ name: String,
        maxBytes: Int = Limits.maxDisplayNameBytes
    ) -> String {
        let cleaned = UnicodeScalarPolicy.removingDisallowed(from: name)
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        var byteCount = 0
        for character in cleaned {
            let characterBytes = character.utf8.count
            guard byteCount + characterBytes <= maxBytes else { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
