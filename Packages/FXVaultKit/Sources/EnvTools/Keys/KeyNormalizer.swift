import VaultCore

/// The result of checking one `.env` key against GitHub's secret and variable name rules.
public struct KeyNormalizationModel: Sendable, Hashable {
    /// How far the key is from a valid GitHub name.
    public enum Status: Sendable, Hashable {
        /// Already valid and uppercase.
        case valid
        /// Valid once uppercased (`api_url` → `API_URL`); no user action needed.
        case uppercased
        /// Breaks a GitHub rule. ``KeyNormalizationModel/proposedKey`` holds a suggested fix,
        /// or nil when nothing usable remains (the user must type a name).
        case needsFix(NameRule)
    }

    /// The key as written in the file.
    public let originalKey: String
    public let status: Status
    /// The name FX Vault proposes: the uppercase key, the suggested fix, or nil.
    public let proposedKey: String?

    public init(originalKey: String, status: Status, proposedKey: String?) {
        self.originalKey = originalKey
        self.status = status
        self.proposedKey = proposedKey
    }

    /// True when the user should review the name (anything beyond uppercasing).
    public var needsReview: Bool {
        if case .needsFix = status { return true }
        return false
    }
}

/// Turns `.env` keys into GitHub secret and variable names (M5, §2): uppercases valid keys and
/// suggests fixes for invalid ones with ``GitHubNameValidator/suggestedFix(for:)`` (diacritics
/// stripped, invalid characters replaced with `_`, a leading digit prefixed with `_`, `GITHUB_`
/// replaced with `GH_`).
public enum KeyNormalizer {
    private static let suffixSeparator = "_"

    /// Checks `key` and proposes a GitHub name.
    ///
    /// Examples: `API_URL` → valid; `api_url` → `API_URL`; `api-url` → `API_URL` (needs fix);
    /// `1password` → `_1PASSWORD`; `GITHUB_TOKEN` → `GH_TOKEN`.
    public static func normalize(_ key: String) -> KeyNormalizationModel {
        if let rule = GitHubNameValidator.violation(in: key) {
            return KeyNormalizationModel(
                originalKey: key,
                status: .needsFix(rule),
                proposedKey: GitHubNameValidator.suggestedFix(for: key)
            )
        }
        let normalized = GitHubNameValidator.normalize(key)
        return KeyNormalizationModel(
            originalKey: key,
            status: normalized == key ? .valid : .uppercased,
            proposedKey: normalized
        )
    }

    /// `proposedKey` if its fold key is not in `takenKeys`, otherwise the first free
    /// `<KEY>_2` ... `<KEY>_99` (the base is shortened when the name would exceed GitHub's length
    /// limit), or nil when none is free. `takenKeys` holds ``GitHubNameValidator/foldKey(_:)``
    /// values.
    public static func uniqueKey(from proposedKey: String, avoiding takenKeys: Set<String>) -> String? {
        let base = GitHubNameValidator.normalize(proposedKey)
        if !takenKeys.contains(GitHubNameValidator.foldKey(base)), GitHubNameValidator.isValid(base) {
            return base
        }
        for number in EnvToolsLimits.firstUniqueKeySuffix...EnvToolsLimits.maxUniqueKeySuffix {
            let suffix = suffixSeparator + String(number)
            let room = Limits.maxConfigNameLength - suffix.utf8.count
            let candidate = String(base.prefix(room)) + suffix
            if GitHubNameValidator.isValid(candidate),
               !takenKeys.contains(GitHubNameValidator.foldKey(candidate)) {
                return candidate
            }
        }
        return nil
    }
}
