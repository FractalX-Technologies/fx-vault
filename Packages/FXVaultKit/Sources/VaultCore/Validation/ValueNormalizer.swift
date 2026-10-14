/// Trailing newline normalization and size checks for secret and variable values (D32).
///
/// `gh secret set` and `gh variable set` strip every trailing `\r` and `\n` from stdin, so FX
/// Vault strips them first: on every entry path (editor, .env import, share import, fill) and,
/// for values stored as listed from GitHub, at push time in `SyncPlanner`. The caller shows a
/// notice when ``NormalizedValue/didStripTrailingNewlines`` is true.
///
/// After stripping, a value must be non-empty (gh drops empty variable values) and at most
/// ``Limits/maxValueBytes`` bytes.
public enum ValueNormalizer {
    private static let carriageReturn = UInt8(ascii: "\r")
    private static let lineFeed = UInt8(ascii: "\n")

    /// A normalized secret value. The caller owns ``value`` and wipes it.
    public struct NormalizedValue: Sendable {
        /// The value without trailing CR/LF, in a new buffer (the input is left untouched).
        public let value: SecretBytes
        /// True when at least one trailing CR or LF was removed.
        public let didStripTrailingNewlines: Bool
    }

    /// A normalized value held as a `String` (the editor's own copy, §5.12).
    public struct NormalizedString: Sendable, Hashable {
        public let value: String
        public let didStripTrailingNewlines: Bool
    }

    /// Strips trailing CR/LF from `value` and checks the result.
    public static func normalize(_ value: SecretBytes) throws(ValidationError) -> NormalizedValue {
        let keptCount = value.withUnsafeBytes { bytes in
            bytes.count - trailingNewlineCount(in: bytes)
        }
        try validate(byteCount: keptCount)
        return NormalizedValue(
            value: value.prefix(keptCount),
            didStripTrailingNewlines: keptCount != value.count
        )
    }

    /// Strips trailing CR/LF from `value` and checks the result.
    public static func normalize(_ value: String) throws(ValidationError) -> NormalizedString {
        let stripped = strippingTrailingNewlines(value)
        try validate(byteCount: stripped.utf8.count)
        return NormalizedString(
            value: stripped,
            didStripTrailingNewlines: stripped.utf8.count != value.utf8.count
        )
    }

    /// `value` without trailing CR/LF. Does not check emptiness or size.
    ///
    /// Works on UTF-8 bytes, so a trailing `\r\n` grapheme is handled like two bytes; removing
    /// trailing ASCII bytes always leaves valid UTF-8.
    public static func strippingTrailingNewlines(_ value: String) -> String {
        var utf8 = Array(value.utf8)
        while let last = utf8.last, isNewline(last) {
            utf8.removeLast()
        }
        return String(decoding: utf8, as: UTF8.self)
    }

    /// Throws ``ValidationError/emptyValue`` for 0 bytes and
    /// ``ValidationError/valueTooLarge(limit:)`` above ``Limits/maxValueBytes``.
    public static func validate(byteCount: Int) throws(ValidationError) {
        if byteCount == 0 { throw .emptyValue }
        if byteCount > Limits.maxValueBytes { throw .valueTooLarge(limit: Limits.maxValueBytes) }
    }

    /// The number of trailing CR and LF bytes in `bytes`.
    public static func trailingNewlineCount(in bytes: UnsafeRawBufferPointer) -> Int {
        var count = 0
        var index = bytes.count
        while index > 0, isNewline(bytes[index - 1]) {
            index -= 1
            count += 1
        }
        return count
    }

    private static func isNewline(_ byte: UInt8) -> Bool {
        byte == carriageReturn || byte == lineFeed
    }
}
