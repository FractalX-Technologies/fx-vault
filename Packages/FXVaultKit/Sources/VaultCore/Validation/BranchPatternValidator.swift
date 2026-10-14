/// Deployment branch and tag patterns (§6 `deployment_branch_patterns`, §9.3).
///
/// Rules: 1–255 Unicode scalars, no control, bidi or zero-width characters. Patterns are
/// fnmatch-style and travel in JSON bodies (never in a URL path), so `/` and `*` are allowed.
public enum BranchPatternValidator {
    /// Returns `pattern` unchanged when it is valid.
    @discardableResult
    public static func validate(_ pattern: String) throws(ValidationError) -> String {
        if let rule = violation(in: pattern) {
            throw .invalidName(rule)
        }
        return pattern
    }

    /// True when ``validate(_:)`` would accept `pattern`.
    public static func isValid(_ pattern: String) -> Bool {
        violation(in: pattern) == nil
    }

    /// The first rule `pattern` breaks, or nil.
    public static func violation(in pattern: String) -> NameRule? {
        if pattern.isEmpty { return .empty }
        if let unsafe = UnicodeScalarPolicy.firstViolation(in: pattern) {
            return UnicodeScalarPolicy.nameRule(for: unsafe)
        }
        if pattern.unicodeScalars.count > Limits.maxBranchPatternLength {
            return .tooLong(maxLength: Limits.maxBranchPatternLength)
        }
        return nil
    }
}
