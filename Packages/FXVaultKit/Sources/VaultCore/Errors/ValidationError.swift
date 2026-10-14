/// A rejected name, value or count (§4.4). Carries no localized text; the app maps each case in
/// `ValidationError+Extension.swift`.
public enum ValidationError: Error, Sendable, Hashable {
    /// A secret, variable, environment, repository, owner or pattern name broke a rule.
    case invalidName(NameRule)
    /// A string that becomes a URL path segment or a file name broke a rule (D29).
    case invalidPathSegment(PathSegmentRule)
    /// The host is not exactly `github.com` (D29).
    case invalidHost
    /// The value is larger than `limit` bytes after normalization (D32).
    case valueTooLarge(limit: Int)
    /// The value is empty after normalization (D32; gh drops empty variable values).
    case emptyValue
    /// The scope already holds the maximum number of items of this kind.
    case scopeFull(kind: ConfigKind, limit: Int)
    /// Another row already uses this name (compared by fold key).
    case duplicateName
    /// The name is still held by a pending rename or deletion of another row (§7.1).
    case nameReservedByPendingChange
    /// Kind or scope cannot change once the item is synced (D11).
    case lockedAfterSync
}

/// The rule a name broke. Shared by every name validator.
public enum NameRule: Sendable, Hashable {
    /// Empty (or only whitespace where whitespace is trimmed).
    case empty
    /// Longer than the validator's limit (`maxLength` in that validator's unit).
    case tooLong(maxLength: Int)
    /// Contains a character outside the allowed set.
    case invalidCharacter
    /// The first character is not allowed there (for example a hyphen in an owner login).
    case invalidFirstCharacter
    /// Starts with a digit (GitHub secrets and variables).
    case leadingDigit
    /// Starts with `GITHUB_` (GitHub secrets and variables).
    case reservedPrefix
    /// `.` or `..` (repository names).
    case dotName
    /// Ends with `.git` (repository names).
    case gitSuffix
    /// Contains a C0 or C1 control character or DEL.
    case controlCharacter
    /// Contains a bidirectional formatting character.
    case bidiCharacter
    /// Contains a zero-width or other invisible formatting character.
    case zeroWidthCharacter
    /// Starts or ends with whitespace.
    case leadingOrTrailingWhitespace
    /// Not in Unicode Normalization Form C (strict checks on imported data).
    case notNormalized
}

/// The rule a path segment broke (D29, §5.10, §8).
public enum PathSegmentRule: Sendable, Hashable {
    /// Empty.
    case empty
    /// `.` or `..`.
    case dotSegment
    /// A percent-encoded form that decodes to `.` or `..` (`%2E%2E`, `.%2e`, `%252E%252E`).
    case encodedDotSegment
    /// Contains `/` or `\`, literally or percent-encoded (`%2F`, `%5C`).
    case separator
    /// Contains a NUL, C0 or C1 control character or DEL, literally or percent-encoded (`%00`).
    case controlCharacter
    /// Contains a bidirectional formatting character.
    case bidiCharacter
    /// Contains a zero-width or other invisible formatting character.
    case zeroWidthCharacter
}
