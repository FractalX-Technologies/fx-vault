import Foundation
import VaultCore

/// SSH host aliases FX Vault will pass to ssh and git (tasks/todo.md §5.10).
///
/// Rule: `^[A-Za-z0-9][A-Za-z0-9._-]*$`, at most ``maxLength`` characters, and a safe path
/// segment. An alias can therefore never start with `-` (it is also passed after `--`).
public enum SSHAliasValidator {
    /// Longest accepted alias (a DNS name's limit).
    public static let maxLength = 253

    /// True when `alias` is acceptable.
    public static func isValid(_ alias: String) -> Bool {
        guard let first = alias.unicodeScalars.first,
              alias.unicodeScalars.count <= maxLength,
              isAlphanumeric(first),
              alias.unicodeScalars.allSatisfy(isAllowed),
              PathSegmentValidator.isValid(alias)
        else { return false }
        return true
    }

    /// Returns `alias` or throws ``GitError/invalidAlias``.
    @discardableResult
    public static func validate(_ alias: String) throws(GitError) -> String {
        guard isValid(alias) else { throw .invalidAlias }
        return alias
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar))
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        isAlphanumeric(scalar) || scalar == "." || scalar == "_" || scalar == "-"
    }
}
