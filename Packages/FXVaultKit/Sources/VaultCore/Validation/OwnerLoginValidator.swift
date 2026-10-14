/// GitHub user and organization logins (§8 A5, §9.3).
///
/// Rule: `^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$`. Legacy logins may contain consecutive or trailing
/// hyphens, so those are accepted. Valid logins are always safe path segments.
public enum OwnerLoginValidator {
    private static let hyphen: Unicode.Scalar = "-"

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
        if login.unicodeScalars.first == hyphen { return .invalidFirstCharacter }
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
        return scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == hyphen
    }
}
