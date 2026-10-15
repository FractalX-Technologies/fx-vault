/// GitHub user and organization logins (§8 A5, §9.3).
///
/// Rule: `^[A-Za-z0-9][A-Za-z0-9_-]{0,38}$`.
/// - Personal and organization logins are ASCII letters, digits and hyphens. Legacy logins may
///   contain consecutive or trailing hyphens, so those are accepted.
/// - Enterprise Managed User logins are the normalized identity-provider handle, an underscore
///   and the enterprise short code (`octocat_octo`, `mona-cat-e_acme`; the setup user is
///   `<short code>_admin`). GitHub counts the underscore and the short code toward the same
///   39-character limit (docs.github.com, "Username considerations for external
///   authentication"). EMU users own personal repositories, so every owner field accepts them.
///   An underscore is accepted anywhere except first.
///
/// Valid logins are always safe path segments (no `/`, `\`, `.` or `..`, no control, bidi or
/// zero-width characters).
public enum OwnerLoginValidator {
    private static let hyphen: Unicode.Scalar = "-"
    private static let underscore: Unicode.Scalar = "_"

    /// Returns `login` unchanged when it is valid.
    @discardableResult
    public static func validate(_ login: String) throws(ValidationError) -> String {
        if let rule = violation(in: login) {
            throw .invalidName(rule)
        }
        return login
    }

    /// True when ``validate(_:)`` would accept `login`.
    public static func isValid(_ login: String) -> Bool {
        violation(in: login) == nil
    }

    /// The first rule `login` breaks, or nil.
    public static func violation(in login: String) -> NameRule? {
        if login.isEmpty { return .empty }
        if let unsafe = UnicodeScalarPolicy.firstViolation(in: login) {
            return UnicodeScalarPolicy.nameRule(for: unsafe)
        }
        guard login.unicodeScalars.allSatisfy(isAllowed) else { return .invalidCharacter }
        if let first = login.unicodeScalars.first, first == hyphen || first == underscore {
            return .invalidFirstCharacter
        }
        if login.utf8.count > Limits.maxOwnerLoginLength {
            return .tooLong(maxLength: Limits.maxOwnerLoginLength)
        }
        return nil
    }

    /// The comparison key: ASCII lowercase (logins are case-insensitive).
    public static func foldKey(_ login: String) -> String {
        login.lowercased()
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else { return false }
        return scalar.properties.isAlphabetic
            || ("0"..."9").contains(scalar)
            || scalar == hyphen
            || scalar == underscore
    }
}
