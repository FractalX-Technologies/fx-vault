/// A problem found while parsing a `.env` file, tied to a 1-based line number (M5).
///
/// Issues carry no value bytes and no localized text; the app maps them in
/// `EnvParseIssue+Extension.swift`. Keys are included because they are not secret.
public struct EnvParseIssue: Sendable, Hashable {
    /// What went wrong.
    public enum Kind: Sendable, Hashable {
        /// A non-comment line has no `=` (for example `export FOO` or `hello world`). The issue
        /// carries no key, because the line's first token may be a value.
        case missingEquals
        /// The line starts with `=`.
        case emptyKey
        /// The key is not valid UTF-8 or contains a control character.
        case invalidKey
        /// A quoted value has no closing quote before the end of the file. Parsing resumes on
        /// the line after the opening quote.
        case unterminatedQuote
        /// Something other than whitespace or a `#` comment follows a closing quote
        /// (`KEY="a"b`).
        case unexpectedCharactersAfterQuote
        /// The value is not valid UTF-8.
        case invalidEncoding
        /// An unquoted value starts a PEM block (`-----BEGIN ...`) that spans lines. The block,
        /// up to its `-----END ...` line (or the end of the file), was skipped; quoting the
        /// value fixes it.
        case unquotedMultilineValue
        /// The key appeared before, last on `previousLine`; this later value wins.
        case duplicateKey(previousLine: Int)
        /// The value contains `${`. Variables are not expanded: the text is kept as written.
        case variableExpansionNotSupported
        /// A double-quoted value contains a backslash escape other than `\n \r \t \" \\ \$`.
        /// The backslash is kept as written.
        case unknownEscapeSequence
    }

    /// Whether the entry was kept.
    public enum Severity: Sendable, Hashable {
        /// The entry was kept (with the value as described by the issue).
        case warning
        /// The line (or quoted block) was skipped; no entry was produced.
        case error
    }

    /// 1-based line number of the entry (the line holding the key for multi-line values).
    public let line: Int
    /// What went wrong.
    public let kind: Kind
    /// The key, when one was read. Never a value.
    public let key: String?

    public init(line: Int, kind: Kind, key: String?) {
        self.line = line
        self.kind = kind
        self.key = key
    }

    /// ``Severity/warning`` when the entry was kept, ``Severity/error`` when it was skipped.
    public var severity: Severity {
        switch kind {
        case .missingEquals, .emptyKey, .invalidKey, .unterminatedQuote,
             .unexpectedCharactersAfterQuote, .invalidEncoding, .unquotedMultilineValue:
            .error
        case .duplicateKey, .variableExpansionNotSupported, .unknownEscapeSequence:
            .warning
        }
    }
}
