import VaultCore

/// One `KEY=value` pair from (or for) a `.env` file.
///
/// The value lives in a ``SecretBytes`` buffer the entry owns; it is wiped when the last
/// reference goes away, or earlier with `value.wipe()`. Printing an entry never shows the value.
public struct DotEnvEntryModel: Sendable, Equatable {
    /// The key exactly as written (not normalized; see ``KeyNormalizer``).
    public let key: String
    /// The decoded value (quotes removed, escapes applied).
    public let value: SecretBytes
    /// 1-based line of the key in the parsed file, or nil for entries built in code.
    public let line: Int?

    public init(key: String, value: SecretBytes, line: Int? = nil) {
        self.key = key
        self.value = value
        self.line = line
    }
}

/// The output of ``DotEnvParser``: the entries that parsed, in first-appearance order with
/// duplicates resolved (last wins), and every issue found, ordered by line.
public struct DotEnvParseResult: Sendable {
    public let entries: [DotEnvEntryModel]
    public let issues: [EnvParseIssue]

    public init(entries: [DotEnvEntryModel], issues: [EnvParseIssue]) {
        self.entries = entries
        self.issues = issues
    }

    /// True when at least one line was skipped.
    public var hasErrors: Bool {
        issues.contains { $0.severity == .error }
    }

    /// Issues for one line.
    public func issues(onLine line: Int) -> [EnvParseIssue] {
        issues.filter { $0.line == line }
    }
}

/// A fatal parse failure (the whole file is rejected).
public enum DotEnvParseError: Error, Sendable, Hashable {
    /// The file is larger than ``EnvToolsLimits/maxEnvFileBytes``.
    case fileTooLarge(limit: Int)
}
