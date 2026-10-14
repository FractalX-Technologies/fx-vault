import Foundation

/// GitHub environment names (§6 `environments`, §7.1, §9.3).
///
/// Rules: 1–255 Unicode scalars (the unit SQLite's `length()` uses), NFC, no control, bidi or
/// zero-width characters, no leading or trailing whitespace, and safe as a URL path segment
/// (``PathSegmentValidator``: no `.`, `..`, `/`, `\` or encoded dot segments). GitHub itself
/// allows `/` in environment names; FX Vault rejects it to rule out path confusion (D29).
///
/// Names compare case-insensitively through ``foldKey(_:)``: `Producción` and `PRODUCCIÓN` (in
/// either composed or decomposed form) share the key `producción`.
public enum EnvironmentNameValidator {
    /// Validates `name` and returns its NFC form, which is what the vault stores.
    ///
    /// - Parameter requireNFC: when true (imported data: share packages, database loads) a name
    ///   that is not already NFC is rejected with ``NameRule/notNormalized`` instead of being
    ///   normalized.
    @discardableResult
    public static func validate(
        _ name: String,
        requireNFC: Bool = false
    ) throws(ValidationError) -> String {
        if let error = violation(in: name, requireNFC: requireNFC) {
            throw error
        }
        return normalize(name)
    }

    /// True when ``validate(_:requireNFC:)`` would accept `name`.
    public static func isValid(_ name: String, requireNFC: Bool = false) -> Bool {
        violation(in: name, requireNFC: requireNFC) == nil
    }

    /// The first error `name` produces, or nil.
    public static func violation(in name: String, requireNFC: Bool = false) -> ValidationError? {
        if name.isEmpty { return .invalidName(.empty) }
        let normalized = normalize(name)
        if requireNFC, normalized.unicodeScalars.elementsEqual(name.unicodeScalars) == false {
            return .invalidName(.notNormalized)
        }
        if let unsafe = UnicodeScalarPolicy.firstViolation(in: normalized) {
            return .invalidName(UnicodeScalarPolicy.nameRule(for: unsafe))
        }
        if let first = normalized.unicodeScalars.first, let last = normalized.unicodeScalars.last,
           first.properties.isWhitespace || last.properties.isWhitespace {
            return .invalidName(.leadingOrTrailingWhitespace)
        }
        if normalized.unicodeScalars.count > Limits.maxEnvironmentNameLength {
            return .invalidName(.tooLong(maxLength: Limits.maxEnvironmentNameLength))
        }
        if let rule = PathSegmentValidator.violation(in: normalized) {
            return .invalidPathSegment(rule)
        }
        return nil
    }

    /// NFC (Unicode canonical composition). Does not validate.
    public static func normalize(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }

    /// `name_key`: NFC, then Swift `lowercased()` (a Unicode case mapping), then NFC again so the
    /// key is stable. SQLite `NOCASE` is never used for Unicode (§6).
    public static func foldKey(_ name: String) -> String {
        normalize(normalize(name).lowercased())
    }

    /// Throws when `name`'s fold key equals another environment's `name_key`
    /// (``ValidationError/duplicateName``) or the `synced_name_key` of an environment with a
    /// pending rename or deletion (``ValidationError/nameReservedByPendingChange``, §7.1).
    /// Keys are ``foldKey(_:)`` values; exclude the row being renamed from both sets.
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
}
