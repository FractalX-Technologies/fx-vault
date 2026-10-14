import Foundation

/// GitHub repository names (§9.3, M4 create).
///
/// Rules: `^[A-Za-z0-9._-]{1,100}$`, not `.` or `..`, and not ending in `.git` (any case).
/// Valid names are always safe path segments. GitHub may still normalize a created name; the
/// name gh prints after `gh repo create` is authoritative (§8 C1).
public enum RepoNameValidator {
    /// The suffix GitHub reserves.
    public static let gitSuffix = ".git"
    private static let dotNames: Set<String> = [".", ".."]
    private static let replacement: Character = "-"

    /// Returns `name` unchanged when it is valid.
    @discardableResult
    public static func validate(_ name: String) throws(ValidationError) -> String {
        if let rule = violation(in: name) {
            throw .invalidName(rule)
        }
        return name
    }

    /// True when ``validate(_:)`` would accept `name`.
    public static func isValid(_ name: String) -> Bool {
        violation(in: name) == nil
    }

    /// The first rule `name` breaks, or nil.
    public static func violation(in name: String) -> NameRule? {
        if name.isEmpty { return .empty }
        if let unsafe = UnicodeScalarPolicy.firstViolation(in: name) {
            return UnicodeScalarPolicy.nameRule(for: unsafe)
        }
        guard name.unicodeScalars.allSatisfy(isAllowed) else { return .invalidCharacter }
        if name.utf8.count > Limits.maxRepoNameLength {
            return .tooLong(maxLength: Limits.maxRepoNameLength)
        }
        if dotNames.contains(name) { return .dotName }
        if foldKey(name).hasSuffix(gitSuffix) { return .gitSuffix }
        return nil
    }

    /// The comparison key: ASCII lowercase (the database index uses `NOCASE`, §6).
    public static func foldKey(_ name: String) -> String {
        name.lowercased()
    }

    /// A valid name close to `name` (diacritics stripped, other character runs replaced with `-`
    /// as GitHub does, a `.git` suffix removed, truncated), or nil when `name` is already valid
    /// or nothing usable remains. Example: `My App` → `My-App`.
    public static func suggestedFix(for name: String) -> String? {
        guard !isValid(name) else { return nil }
        let folded = UnicodeScalarPolicy.removingDisallowed(from: name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        var candidate = folded.unicodeScalars
            .split(whereSeparator: { !isAllowed($0) })
            .map { String($0) }
            .joined(separator: String(replacement))
        while foldKey(candidate).hasSuffix(gitSuffix) {
            candidate = String(candidate.dropLast(gitSuffix.count))
        }
        if candidate.utf8.count > Limits.maxRepoNameLength {
            candidate = String(candidate.prefix(Limits.maxRepoNameLength))
        }
        return isValid(candidate) ? candidate : nil
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else { return false }
        return scalar.properties.isAlphabetic
            || ("0"..."9").contains(scalar)
            || scalar == "."
            || scalar == "_"
            || scalar == "-"
    }
}
