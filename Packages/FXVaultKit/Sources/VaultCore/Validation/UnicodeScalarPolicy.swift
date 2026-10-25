/// Classifies the Unicode scalars FX Vault never accepts in names (D29, §9.3).
///
/// Shared by every validator and sanitizer so the sets cannot drift apart.
/// - Control: C0 (U+0000–U+001F), DEL (U+007F), C1 (U+0080–U+009F), plus the line and paragraph
///   separators U+2028 and U+2029.
/// - Bidi: U+200E, U+200F, U+202A–U+202E, U+2066–U+2069 and the Arabic letter mark U+061C.
/// - Zero-width / invisible: U+200B–U+200D, U+2060 (word joiner) and U+FEFF (BOM).
public enum UnicodeScalarPolicy {
    /// The kind of disallowed scalar, in the order validators report them.
    public enum Violation: Sendable, Hashable, CaseIterable {
        case control
        case bidi
        case zeroWidth
    }

    private static let c0Controls: ClosedRange<UInt32> = 0x0000...0x001F
    private static let delete: UInt32 = 0x007F
    private static let c1Controls: ClosedRange<UInt32> = 0x0080...0x009F
    private static let lineAndParagraphSeparators: ClosedRange<UInt32> = 0x2028...0x2029

    private static let bidiMarks: ClosedRange<UInt32> = 0x200E...0x200F
    private static let bidiEmbeddings: ClosedRange<UInt32> = 0x202A...0x202E
    private static let bidiIsolates: ClosedRange<UInt32> = 0x2066...0x2069
    private static let arabicLetterMark: UInt32 = 0x061C

    private static let zeroWidthSpaceJoiners: ClosedRange<UInt32> = 0x200B...0x200D
    private static let wordJoiner: UInt32 = 0x2060
    private static let byteOrderMark: UInt32 = 0xFEFF

    private static let hangulFillers: Set<UInt32> = [0x115F, 0x1160, 0x3164, 0xFFA0]
    private static let combiningGraphemeJoiner: UInt32 = 0x034F

    /// C0, DEL, C1 and the line/paragraph separators.
    public static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return c0Controls.contains(value)
            || value == delete
            || c1Controls.contains(value)
            || lineAndParagraphSeparators.contains(value)
    }

    /// Bidirectional formatting characters (Trojan Source).
    public static func isBidi(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return bidiMarks.contains(value)
            || bidiEmbeddings.contains(value)
            || bidiIsolates.contains(value)
            || value == arabicLetterMark
    }

    /// Zero-width and invisible joiners.
    public static func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return zeroWidthSpaceJoiners.contains(value)
            || value == wordJoiner
            || value == byteOrderMark
    }

    /// Scalars that render as nothing or as blank space, so they can hide text shown from another
    /// person: every format character (General_Category `Cf`: soft hyphen, invisible operators,
    /// tag characters, interlinear annotation, U+180E, besides the bidi and zero-width ones), the
    /// Hangul fillers and the combining grapheme joiner. Not a name ``Violation``: validators
    /// keep their rules; display sanitizers (sender names) drop these too.
    public static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .format
            || hangulFillers.contains(scalar.value)
            || scalar.value == combiningGraphemeJoiner
    }

    /// The violation for one scalar, or nil if it is allowed.
    public static func violation(of scalar: Unicode.Scalar) -> Violation? {
        if isControl(scalar) { return .control }
        if isBidi(scalar) { return .bidi }
        if isZeroWidth(scalar) { return .zeroWidth }
        return nil
    }

    /// The first violation in a string, scanning scalars in order. Nil if the string is clean.
    public static func firstViolation(in string: String) -> Violation? {
        for scalar in string.unicodeScalars {
            if let violation = violation(of: scalar) { return violation }
        }
        return nil
    }

    /// The string with every disallowed scalar removed.
    public static func removingDisallowed(from string: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: string.unicodeScalars.filter { violation(of: $0) == nil })
        return String(scalars)
    }

    /// For text shown from another person: every disallowed and every invisible scalar removed.
    public static func removingDisallowedAndInvisible(from string: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: string.unicodeScalars.filter { violation(of: $0) == nil && !isInvisible($0) })
        return String(scalars)
    }

    /// Maps a violation onto the shared name rule.
    public static func nameRule(for violation: Violation) -> NameRule {
        switch violation {
        case .control: .controlCharacter
        case .bidi: .bidiCharacter
        case .zeroWidth: .zeroWidthCharacter
        }
    }
}
