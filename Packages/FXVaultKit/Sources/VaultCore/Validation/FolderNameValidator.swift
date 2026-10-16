import Foundation

/// Folder names (v0.7.0, `folders.name`).
///
/// Rules: 1–``Limits/maxFolderNameLength`` Unicode scalars, NFC, no control, bidi or zero-width
/// characters, no leading or trailing whitespace. A folder name never reaches GitHub or a path,
/// so it may contain `/` and dots. Names compare case-insensitively through ``foldKey(_:)``.
public enum FolderNameValidator {
    /// Validates `name` and returns its NFC form, which is what the vault stores.
    ///
    /// - Parameter requireNFC: when true (a name from a share package) a name that is not
    ///   already NFC is rejected with ``NameRule/notNormalized`` instead of being normalized.
    @discardableResult
    public static func validate(_ name: String, requireNFC: Bool = false) throws(ValidationError) -> String {
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
        if requireNFC, !normalized.unicodeScalars.elementsEqual(name.unicodeScalars) {
            return .invalidName(.notNormalized)
        }
        if let unsafe = UnicodeScalarPolicy.firstViolation(in: normalized) {
            return .invalidName(UnicodeScalarPolicy.nameRule(for: unsafe))
        }
        if let first = normalized.unicodeScalars.first, let last = normalized.unicodeScalars.last,
           first.properties.isWhitespace || last.properties.isWhitespace {
            return .invalidName(.leadingOrTrailingWhitespace)
        }
        if normalized.unicodeScalars.count > Limits.maxFolderNameLength {
            return .invalidName(.tooLong(maxLength: Limits.maxFolderNameLength))
        }
        return nil
    }

    /// NFC (Unicode canonical composition). Does not validate.
    public static func normalize(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }

    /// `name_key`: NFC, lowercased, NFC again (as ``EnvironmentNameValidator/foldKey(_:)``).
    public static func foldKey(_ name: String) -> String {
        normalize(normalize(name).lowercased())
    }
}
