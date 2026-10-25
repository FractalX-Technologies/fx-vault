import Foundation

/// GitHub Actions secret and variable names (§2, §7.3 preflight).
///
/// GitHub accepts `[A-Za-z0-9_]`, no leading digit, no `GITHUB_` prefix, and stores names in
/// uppercase. FX Vault uppercases on entry, so a valid name always matches
/// `^[A-Z_][A-Z0-9_]*$` after ``validate(_:)``. Characters are checked **before** uppercasing,
/// so `straße` is rejected instead of silently becoming `STRASSE`.
public enum GitHubNameValidator {
    /// GitHub reserves this prefix.
    public static let reservedPrefix = "GITHUB_"
    /// The variable 0.6–0.9 wrote in a shared scope (S4): its version marker. Still reserved for
    /// user items and dropped from listings, so a marker left on GitHub never shows as a variable.
    public static let spaceMarkerName = "FXVAULT_SPACE"
    /// Replacement prefix offered by ``suggestedFix(for:)`` for reserved names.
    public static let suggestedPrefix = "GH_"
    private static let underscore: Character = "_"

    /// Validates `name` and returns it uppercased.
    @discardableResult
    public static func validate(_ name: String) throws(ValidationError) -> String {
        if let rule = violation(in: name) {
            throw .invalidName(rule)
        }
        return normalize(name)
    }

    /// True when ``validate(_:)`` would accept `name`.
    public static func isValid(_ name: String) -> Bool {
        violation(in: name) == nil
    }

    /// The first rule `name` breaks, or nil. Order: empty, characters, leading digit, reserved
    /// prefix, reserved name, length.
    public static func violation(in name: String) -> NameRule? {
        if name.isEmpty { return .empty }
        if let unsafe = UnicodeScalarPolicy.firstViolation(in: name) {
            return UnicodeScalarPolicy.nameRule(for: unsafe)
        }
        guard name.unicodeScalars.allSatisfy(isAllowed) else { return .invalidCharacter }
        if let first = name.unicodeScalars.first, isDigit(first) { return .leadingDigit }
        if normalize(name).hasPrefix(reservedPrefix) { return .reservedPrefix }
        if normalize(name) == spaceMarkerName { return .reservedName }
        if name.utf8.count > Limits.maxConfigNameLength {
            return .tooLong(maxLength: Limits.maxConfigNameLength)
        }
        return nil
    }

    /// The stored form: ASCII uppercase. Does not validate.
    public static func normalize(_ name: String) -> String {
        name.uppercased()
    }

    /// The comparison key (GitHub names are case-insensitive): the uppercase form.
    public static func foldKey(_ name: String) -> String {
        normalize(name)
    }

    /// A valid name close to `name` (diacritics stripped, other characters replaced with `_`,
    /// leading digit prefixed with `_`, `GITHUB_` replaced with `GH_`, truncated), or nil when
    /// `name` is already valid or nothing usable remains.
    ///
    /// Example: `Producción-key` → `PRODUCCION_KEY`; `1password` → `_1PASSWORD`.
    public static func suggestedFix(for name: String) -> String? {
        guard !isValid(name) else { return nil }
        let folded = UnicodeScalarPolicy.removingDisallowed(from: name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        let parts = folded.unicodeScalars
            .split(whereSeparator: { !isAllowed($0) })
            .map { String($0) }
        var candidate = normalize(parts.joined(separator: String(underscore)))
        guard !candidate.isEmpty else { return nil }
        if let first = candidate.unicodeScalars.first, isDigit(first) {
            candidate.insert(underscore, at: candidate.startIndex)
        }
        if candidate.hasPrefix(reservedPrefix) {
            candidate = suggestedPrefix + candidate.dropFirst(reservedPrefix.count)
        }
        if candidate.utf8.count > Limits.maxConfigNameLength {
            candidate = String(candidate.prefix(Limits.maxConfigNameLength))
        }
        return isValid(candidate) ? candidate : nil
    }

    /// Throws when `name`'s fold key is already used by another row in the same scope and kind
    /// (``ValidationError/duplicateName``) or held by a pending rename or deletion
    /// (``ValidationError/nameReservedByPendingChange``). Keys are ``foldKey(_:)`` values.
    public static func checkAvailability(
        of name: String,
        takenKeys: Set<String>,
        reservedKeys: Set<String> = []
    ) throws(ValidationError) {
        try NameAvailability.check(
            key: foldKey(name),
            takenKeys: takenKeys,
            reservedKeys: reservedKeys
        )
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || isDigit(scalar) || scalar == "_")
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }
}
