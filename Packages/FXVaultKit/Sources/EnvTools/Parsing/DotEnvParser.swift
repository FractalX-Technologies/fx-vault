import VaultCore

/// Parses `.env` files (M5).
///
/// Grammar, line by line (lines end in `\n` or `\r\n`; a leading UTF-8 BOM is skipped):
/// - Blank lines and lines whose first non-blank character is `#` are ignored.
/// - An optional `export` keyword followed by a space or tab is skipped.
/// - `KEY=value`: the key runs up to `=` or whitespace; spaces and tabs around `=` are allowed.
/// - **Unquoted** values run to the end of the line, minus trailing spaces and tabs. A `#`
///   starts an inline comment only when the character before it is a space or tab, so
///   `KEY=a#b` keeps `a#b` and `KEY=a #b` gives `a`.
/// - **Single-quoted** values are literal (no escapes) and may span lines.
/// - **Double-quoted** values may span lines and understand `\n \r \t \" \\` and `\$`. Any
///   other escape is kept as written, with a warning.
/// - Inside quotes, a `\r\n` line break becomes `\n`.
/// - After a closing quote only whitespace and an optional `#` comment may follow.
/// - Variables are **not** expanded: `${...}` in unquoted or double-quoted values is kept as
///   written, with a warning (`\${` suppresses it).
/// - A repeated key keeps its first position, takes the later value (last wins) and gets a
///   warning.
///
/// Values are decoded straight into ``SecretBytes`` buffers through a scratch buffer that is
/// wiped afterwards, so no value is copied into a `String` or `Array`. The caller owns the
/// input buffer and wipes it.
public enum DotEnvParser {
    /// Parses the UTF-8 bytes of a `.env` file.
    public static func parse(_ contents: SecretBytes) throws(DotEnvParseError) -> DotEnvParseResult {
        guard contents.count <= EnvToolsLimits.maxEnvFileBytes else {
            throw .fileTooLarge(limit: EnvToolsLimits.maxEnvFileBytes)
        }
        // A decoded value is never longer than the input, so one scratch buffer of the input's
        // size holds any value.
        let scratch = SecretBytes(count: contents.count)
        defer { scratch.wipe() }
        return contents.withUnsafeBytes { input in
            scratch.withUnsafeMutableBytes { buffer in
                var scanner = DotEnvScanner(input: input, scratch: buffer)
                return scanner.run()
            }
        }
    }

    /// Parses `.env` text. Convenience for tests and previews; prefer the `SecretBytes`
    /// overload for real files.
    public static func parse(_ text: String) throws(DotEnvParseError) -> DotEnvParseResult {
        try parse(SecretBytes(utf8: text))
    }
}

/// The single-pass scanner behind ``DotEnvParser``. Lives only inside the parse closures, so
/// the buffer pointers never escape.
private struct DotEnvScanner {
    private static let exportKeyword = Array("export".utf8)

    let input: UnsafeRawBufferPointer
    let scratch: UnsafeMutableRawBufferPointer

    private var position = 0
    private var line = 1
    private var entries: [DotEnvEntryModel] = []
    private var entryIndexByKey: [String: Int] = [:]
    private var issues: [EnvParseIssue] = []

    init(input: UnsafeRawBufferPointer, scratch: UnsafeMutableRawBufferPointer) {
        self.input = input
        self.scratch = scratch
    }

    mutating func run() -> DotEnvParseResult {
        if ByteScanning.matches(ASCII.byteOrderMark, in: input, at: 0) {
            position = ASCII.byteOrderMark.count
        }
        while position < input.count {
            parseLine()
        }
        // Stable sort: issues on the same line keep the order they were found in.
        let ordered = issues.enumerated()
            .sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }
            .map(\.element)
        return DotEnvParseResult(entries: entries, issues: ordered)
    }

    // MARK: - Lines

    private mutating func parseLine() {
        let startLine = line
        skipHorizontalWhitespace()
        if isAtLineEnd {
            consumeLineEnd()
            return
        }
        if current == ASCII.hash {
            skipRestOfLine()
            return
        }
        skipExportKeyword()

        let keyStart = position
        while !isAtLineEnd, let byte = current, byte != ASCII.equals, !ASCII.isHorizontalWhitespace(byte) {
            position += 1
        }
        let keyRange = keyStart..<position
        skipHorizontalWhitespace()

        guard current == ASCII.equals else {
            report(.missingEquals, line: startLine, key: decodeKey(keyRange))
            skipRestOfLine()
            return
        }
        guard !keyRange.isEmpty else {
            report(.emptyKey, line: startLine, key: nil)
            skipRestOfLine()
            return
        }
        guard let key = decodeKey(keyRange) else {
            report(.invalidKey, line: startLine, key: nil)
            skipRestOfLine()
            return
        }

        position += 1
        skipHorizontalWhitespace()
        switch current {
        case ASCII.singleQuote, ASCII.doubleQuote:
            parseQuotedValue(key: key, startLine: startLine)
        default:
            parseUnquotedValue(key: key, startLine: startLine)
        }
    }

    // MARK: - Values

    private mutating func parseUnquotedValue(key: String, startLine: Int) {
        let valueStart = position
        while !isAtLineEnd {
            // `position > valueStart` is not required: the byte before the value is `=` or
            // whitespace, and whitespace before `#` means a comment (`KEY= #c` is empty).
            if input[position] == ASCII.hash, ASCII.isHorizontalWhitespace(input[position - 1]) {
                break
            }
            position += 1
        }
        var valueEnd = position
        while valueEnd > valueStart, ASCII.isHorizontalWhitespace(input[valueEnd - 1]) {
            valueEnd -= 1
        }
        let length = valueEnd - valueStart
        if length > 0 {
            UnsafeMutableRawBufferPointer(rebasing: scratch[0..<length])
                .copyMemory(from: UnsafeRawBufferPointer(rebasing: input[valueStart..<valueEnd]))
        }
        let value = UnsafeRawBufferPointer(rebasing: scratch[0..<length])
        let hasExpansion = ByteScanning.contains([ASCII.dollar, ASCII.openBrace], in: value)
        skipRestOfLine()

        var warnings: [EnvParseIssue.Kind] = []
        if hasExpansion { warnings.append(.variableExpansionNotSupported) }
        finishEntry(key: key, length: length, startLine: startLine, warnings: warnings)
    }

    private mutating func parseQuotedValue(key: String, startLine: Int) {
        guard let quote = current else { return }
        let isDouble = quote == ASCII.doubleQuote
        let openingPosition = position
        position += 1

        var length = 0
        var isClosed = false
        var hasExpansion = false
        var hasUnknownEscape = false

        while position < input.count {
            let byte = input[position]
            if byte == quote {
                isClosed = true
                position += 1
                break
            }
            if byte == ASCII.carriageReturn, next == ASCII.lineFeed {
                append(ASCII.lineFeed, at: &length)
                position += 2
                line += 1
                continue
            }
            if byte == ASCII.lineFeed {
                append(ASCII.lineFeed, at: &length)
                position += 1
                line += 1
                continue
            }
            if isDouble, byte == ASCII.backslash {
                if let escaped = next.flatMap(Self.decodeEscape) {
                    append(escaped, at: &length)
                    position += 2
                } else {
                    // Unknown escape (or a backslash at the end of the input): keep the
                    // backslash and let the next byte be read normally.
                    append(byte, at: &length)
                    position += 1
                    hasUnknownEscape = true
                }
                continue
            }
            if isDouble, byte == ASCII.dollar, next == ASCII.openBrace {
                hasExpansion = true
            }
            append(byte, at: &length)
            position += 1
        }

        guard isClosed else {
            report(.unterminatedQuote, line: startLine, key: key)
            // Resume on the line after the opening quote.
            position = openingPosition
            line = startLine
            skipRestOfLine()
            return
        }

        skipHorizontalWhitespace()
        guard isAtLineEnd || current == ASCII.hash else {
            report(.unexpectedCharactersAfterQuote, line: startLine, key: key)
            skipRestOfLine()
            return
        }
        skipRestOfLine()

        var warnings: [EnvParseIssue.Kind] = []
        if hasExpansion { warnings.append(.variableExpansionNotSupported) }
        if hasUnknownEscape { warnings.append(.unknownEscapeSequence) }
        finishEntry(key: key, length: length, startLine: startLine, warnings: warnings)
    }

    /// The byte a known double-quote escape (`\n \r \t \" \\ \$`) stands for.
    private static func decodeEscape(_ byte: UInt8) -> UInt8? {
        switch byte {
        case ASCII.letterN: ASCII.lineFeed
        case ASCII.letterR: ASCII.carriageReturn
        case ASCII.letterT: ASCII.tab
        case ASCII.doubleQuote, ASCII.backslash, ASCII.dollar: byte
        default: nil
        }
    }

    private mutating func finishEntry(
        key: String,
        length: Int,
        startLine: Int,
        warnings: [EnvParseIssue.Kind]
    ) {
        let bytes = UnsafeRawBufferPointer(rebasing: scratch[0..<length])
        guard ByteScanning.isValidUTF8(bytes) else {
            report(.invalidEncoding, line: startLine, key: key)
            return
        }
        let entry = DotEnvEntryModel(key: key, value: SecretBytes(copying: bytes), line: startLine)
        if let index = entryIndexByKey[key] {
            report(.duplicateKey(previousLine: entries[index].line ?? startLine), line: startLine, key: key)
            entries[index] = entry
        } else {
            entryIndexByKey[key] = entries.count
            entries.append(entry)
        }
        for warning in warnings {
            report(warning, line: startLine, key: key)
        }
    }

    // MARK: - Keys

    /// The key as a `String`, or nil when it is not valid UTF-8 or contains a control
    /// character. Keys are not secret.
    private func decodeKey(_ range: Range<Int>) -> String? {
        guard !range.isEmpty else { return nil }
        let bytes = UnsafeRawBufferPointer(rebasing: input[range])
        guard ByteScanning.isValidUTF8(bytes), !bytes.contains(where: ASCII.isControl) else {
            return nil
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private mutating func skipExportKeyword() {
        let keywordEnd = position + Self.exportKeyword.count
        guard ByteScanning.matches(Self.exportKeyword, in: input, at: position),
              keywordEnd < input.count,
              ASCII.isHorizontalWhitespace(input[keywordEnd])
        else { return }
        position = keywordEnd
        skipHorizontalWhitespace()
    }

    // MARK: - Cursor

    private var current: UInt8? {
        position < input.count ? input[position] : nil
    }

    private var next: UInt8? {
        position + 1 < input.count ? input[position + 1] : nil
    }

    private var isAtLineEnd: Bool {
        guard let byte = current else { return true }
        return byte == ASCII.lineFeed || (byte == ASCII.carriageReturn && next == ASCII.lineFeed)
    }

    private mutating func skipHorizontalWhitespace() {
        while let byte = current, ASCII.isHorizontalWhitespace(byte) {
            position += 1
        }
    }

    /// Moves past the rest of the current line, including its line break.
    private mutating func skipRestOfLine() {
        while !isAtLineEnd {
            position += 1
        }
        consumeLineEnd()
    }

    private mutating func consumeLineEnd() {
        guard let byte = current else { return }
        position += byte == ASCII.carriageReturn ? 2 : 1
        line += 1
    }

    private func append(_ byte: UInt8, at length: inout Int) {
        scratch[length] = byte
        length += 1
    }

    private mutating func report(_ kind: EnvParseIssue.Kind, line: Int, key: String?) {
        issues.append(EnvParseIssue(line: line, kind: kind, key: key))
    }
}
