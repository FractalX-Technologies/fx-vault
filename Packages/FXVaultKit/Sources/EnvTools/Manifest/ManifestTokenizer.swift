/// How a scalar was written. Only plain scalars can be booleans or integers.
enum ManifestScalarStyle: Sendable, Hashable {
    case plain
    case singleQuoted
    case doubleQuoted
}

/// One token of the manifest's YAML subset.
struct ManifestToken: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        /// A scalar, decoded (quotes removed, escapes applied, plain scalars trimmed).
        case scalar(String, ManifestScalarStyle)
        /// `:` ending a key.
        case colon
        /// `- ` starting a block sequence item.
        case dash
        case comma
        case openBracket
        case closeBracket
        case openBrace
        case closeBrace
        /// A node the tokenizer already reported (an alias, a block scalar, a broken quoted
        /// scalar). The builder keeps it as an invalid node and reports nothing more about it.
        case invalid
    }

    let kind: Kind
    /// 1-based line.
    let line: Int
    /// 0-based column, in UTF-8 bytes from the start of the line.
    let column: Int
    /// True for the first token on its line.
    let startsLine: Bool
}

/// Splits manifest text into ``ManifestToken``s, reporting the constructs outside the subset.
///
/// Works line by line on UTF-8 bytes: line breaks are `\n`, `\r\n` or `\r`, a leading BOM is
/// skipped, and quoted scalars never span lines. Comments (`#` at the start of a line or after
/// whitespace, outside quotes) and blank lines produce nothing. Every path advances by at least
/// one byte or line, so tokenizing always ends.
struct ManifestTokenizer {
    private enum Byte {
        static let tab = UInt8(ascii: "\t")
        static let lineFeed = UInt8(ascii: "\n")
        static let carriageReturn = UInt8(ascii: "\r")
        static let space = UInt8(ascii: " ")
        static let hash = UInt8(ascii: "#")
        static let colon = UInt8(ascii: ":")
        static let dash = UInt8(ascii: "-")
        static let comma = UInt8(ascii: ",")
        static let period = UInt8(ascii: ".")
        static let openBracket = UInt8(ascii: "[")
        static let closeBracket = UInt8(ascii: "]")
        static let openBrace = UInt8(ascii: "{")
        static let closeBrace = UInt8(ascii: "}")
        static let question = UInt8(ascii: "?")
        static let ampersand = UInt8(ascii: "&")
        static let asterisk = UInt8(ascii: "*")
        static let exclamation = UInt8(ascii: "!")
        static let pipe = UInt8(ascii: "|")
        static let greaterThan = UInt8(ascii: ">")
        static let percent = UInt8(ascii: "%")
        static let at = UInt8(ascii: "@")
        static let backtick = UInt8(ascii: "`")
        static let singleQuote = UInt8(ascii: "'")
        static let doubleQuote = UInt8(ascii: "\"")
        static let backslash = UInt8(ascii: "\\")
        static let letterN = UInt8(ascii: "n")
        static let letterT = UInt8(ascii: "t")
    }

    /// `---`: the document start marker (the same byte three times).
    private static let markerLength = 3

    private let bytes: [UInt8]
    private let lines: [Range<Int>]

    private var lineIndex = 0
    private var lineStart = 0
    private var lineEnd = 0
    private var position = 0
    private var flowDepth = 0
    private var tokenOnLine = false
    /// Position right after the last quoted scalar, for JSON-style `"key":value` in flow.
    private var lastQuotedEnd = -1
    private var sawDocumentStart = false
    private var sawContent = false
    private var documentEnded = false
    /// Set by a block scalar or complex key: later lines to skip.
    private var pendingSkip: PendingSkip?

    private(set) var tokens: [ManifestToken] = []
    private(set) var issues: [ManifestIssue] = []

    private enum PendingSkip {
        /// Skip blank lines and lines indented deeper than `indent` (block scalar content).
        case deeperThan(indent: Int)
        /// As above, plus `: value` lines at `indent` (the value of a `? key`).
        case complexKeyAt(indent: Int)
    }

    init(text: String) {
        var bytes = Array(text.utf8)
        if bytes.starts(with: ASCII.byteOrderMark) {
            bytes.removeFirst(ASCII.byteOrderMark.count)
        }
        self.bytes = bytes
        lines = Self.lineRanges(of: bytes)
    }

    /// The content range of every line (line breaks excluded).
    static func lineRanges(of bytes: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case Byte.lineFeed:
                ranges.append(start..<index)
                index += 1
                start = index
            case Byte.carriageReturn:
                ranges.append(start..<index)
                index += 1
                if index < bytes.count, bytes[index] == Byte.lineFeed { index += 1 }
                start = index
            default:
                index += 1
            }
        }
        if start < bytes.count { ranges.append(start..<bytes.count) }
        return ranges
    }

    mutating func run() {
        while lineIndex < lines.count {
            tokenizeLine()
            lineIndex += 1
            applyPendingSkip()
        }
    }

    private var lineNumber: Int {
        lineIndex + 1
    }

    // MARK: - Lines

    private mutating func tokenizeLine() {
        lineStart = lines[lineIndex].lowerBound
        lineEnd = lines[lineIndex].upperBound
        position = lineStart
        tokenOnLine = false

        var hasTab = false
        while position < lineEnd, isInlineSpace(bytes[position]) {
            if bytes[position] == Byte.tab { hasTab = true }
            position += 1
        }
        if position == lineEnd || bytes[position] == Byte.hash { return }
        if documentEnded {
            stopAtSecondDocument()
            return
        }
        if hasTab {
            report(.tabInIndentation)
            return
        }
        let indent = position - lineStart
        if indent == 0, flowDepth == 0 {
            if isMarker(Byte.dash) {
                handleDocumentStart()
                return
            }
            if isMarker(Byte.period) {
                documentEnded = true
                finishMarkerLine()
                return
            }
            if bytes[position] == Byte.percent {
                report(.unsupported(.directive))
                return
            }
        }
        sawContent = true
        scanTokens(indent: indent)
    }

    /// True when the line starts with `---` or `...` followed by whitespace or the line end.
    private func isMarker(_ byte: UInt8) -> Bool {
        let end = position + Self.markerLength
        guard end <= lineEnd, bytes[position..<end].allSatisfy({ $0 == byte }) else { return false }
        return end == lineEnd || isInlineSpace(bytes[end])
    }

    private mutating func handleDocumentStart() {
        guard !sawContent, !sawDocumentStart else {
            stopAtSecondDocument()
            return
        }
        sawDocumentStart = true
        finishMarkerLine()
    }

    /// After `---` or `...` only a comment may follow.
    private mutating func finishMarkerLine() {
        position += Self.markerLength
        while position < lineEnd, isInlineSpace(bytes[position]) { position += 1 }
        if position < lineEnd, bytes[position] != Byte.hash {
            report(.unexpectedContent)
        }
    }

    private mutating func stopAtSecondDocument() {
        report(.unsupported(.multipleDocuments))
        lineIndex = lines.count
    }

    /// Skips the lines a block scalar or complex key owns (see ``PendingSkip``).
    private mutating func applyPendingSkip() {
        guard let skip = pendingSkip else { return }
        pendingSkip = nil
        while lineIndex < lines.count {
            let range = lines[lineIndex]
            var index = range.lowerBound
            while index < range.upperBound, isInlineSpace(bytes[index]) { index += 1 }
            let indent = index - range.lowerBound
            let isBlank = index == range.upperBound
            switch skip {
            case .deeperThan(let parent):
                guard isBlank || indent > parent else { return }
            case .complexKeyAt(let parent):
                let startsValue = indent == parent && bytes[index] == Byte.colon
                    && (index + 1 == range.upperBound || isInlineSpace(bytes[index + 1]))
                guard isBlank || indent > parent || startsValue else { return }
            }
            lineIndex += 1
        }
    }

    // MARK: - Tokens

    private mutating func scanTokens(indent: Int) {
        while position < lineEnd {
            let byte = bytes[position]
            if isInlineSpace(byte) {
                position += 1
                continue
            }
            let column = position - lineStart
            let afterSpace = position == lineStart || isInlineSpace(bytes[position - 1])
            switch byte {
            case Byte.hash:
                // `#` right after a token (`]#`, `,#`) is neither a comment nor a scalar.
                if !afterSpace { report(.unexpectedContent) }
                return
            case Byte.openBracket:
                emitIndicator(.openBracket, column: column)
                flowDepth += 1
            case Byte.openBrace:
                emitIndicator(.openBrace, column: column)
                flowDepth += 1
            case Byte.closeBracket:
                emitIndicator(.closeBracket, column: column)
                flowDepth = max(0, flowDepth - 1)
            case Byte.closeBrace:
                emitIndicator(.closeBrace, column: column)
                flowDepth = max(0, flowDepth - 1)
            case Byte.comma where flowDepth > 0:
                emitIndicator(.comma, column: column)
            case Byte.colon where endsKey(at: position):
                emitIndicator(.colon, column: column)
            case Byte.dash where isSeparator(at: position + 1):
                emitIndicator(.dash, column: column)
            case Byte.question where isSeparator(at: position + 1):
                report(.unsupported(.complexKey))
                guard flowDepth == 0 else {
                    position += 1
                    continue
                }
                // One invalid `key:` stands for the whole entry, so the builder drops it quietly.
                emit(.invalid, column: column)
                emit(.colon, column: column)
                pendingSkip = .complexKeyAt(indent: indent)
                return
            case Byte.ampersand:
                report(.unsupported(.anchor))
                skipWord()
            case Byte.asterisk:
                report(.unsupported(.alias))
                skipWord()
                emit(.invalid, column: column)
            case Byte.exclamation:
                report(.unsupported(.tag))
                skipWord()
            case Byte.pipe where flowDepth == 0, Byte.greaterThan where flowDepth == 0:
                report(.unsupported(.blockScalar))
                emit(.invalid, column: column)
                pendingSkip = .deeperThan(indent: indent)
                return
            case Byte.singleQuote:
                scanSingleQuoted(column: column)
            case Byte.doubleQuote:
                scanDoubleQuoted(column: column)
            case Byte.comma, Byte.pipe, Byte.greaterThan, Byte.percent, Byte.at, Byte.backtick:
                // Indicators that cannot start a plain scalar here.
                report(.unexpectedContent)
                skipWord()
                emit(.invalid, column: column)
            default:
                scanPlain(column: column)
            }
        }
    }

    /// `:` ends a key when whitespace or the line end follows, when a flow indicator follows
    /// inside a flow collection, or right after a quoted key inside one (`{"a":1}`).
    private func endsKey(at index: Int) -> Bool {
        if isSeparator(at: index + 1) { return true }
        guard flowDepth > 0 else { return false }
        return isFlowIndicator(bytes[index + 1]) || lastQuotedEnd == index
    }

    private mutating func scanPlain(column: Int) {
        let start = position
        while position < lineEnd {
            let byte = bytes[position]
            if byte == Byte.colon, endsKey(at: position) { break }
            if flowDepth > 0, isFlowIndicator(byte) { break }
            if byte == Byte.hash, position > start, isInlineSpace(bytes[position - 1]) { break }
            position += 1
        }
        if position == start { position += 1 }
        var end = position
        while end > start, isInlineSpace(bytes[end - 1]) { end -= 1 }
        emit(.scalar(String(decoding: bytes[start..<end], as: UTF8.self), .plain), column: column)
    }

    private mutating func scanSingleQuoted(column: Int) {
        position += 1
        var text: [UInt8] = []
        while true {
            guard position < lineEnd else {
                failQuoted(column: column)
                return
            }
            let byte = bytes[position]
            if byte == Byte.singleQuote {
                if position + 1 < lineEnd, bytes[position + 1] == Byte.singleQuote {
                    text.append(Byte.singleQuote)
                    position += 2
                    continue
                }
                position += 1
                break
            }
            text.append(byte)
            position += 1
        }
        finishQuoted(text, style: .singleQuoted, isValid: true, column: column)
    }

    private mutating func scanDoubleQuoted(column: Int) {
        position += 1
        var text: [UInt8] = []
        var isValid = true
        while true {
            guard position < lineEnd else {
                failQuoted(column: column)
                return
            }
            let byte = bytes[position]
            if byte == Byte.doubleQuote {
                position += 1
                break
            }
            if byte == Byte.backslash {
                // A backslash at the line end would continue the scalar on the next line.
                guard position + 1 < lineEnd else {
                    failQuoted(column: column)
                    return
                }
                switch bytes[position + 1] {
                case Byte.doubleQuote: text.append(Byte.doubleQuote)
                case Byte.backslash: text.append(Byte.backslash)
                case Byte.letterN: text.append(Byte.lineFeed)
                case Byte.letterT: text.append(Byte.tab)
                default: isValid = false
                }
                position += 2
                continue
            }
            text.append(byte)
            position += 1
        }
        if !isValid { report(.invalidEscapeSequence) }
        finishQuoted(text, style: .doubleQuoted, isValid: isValid, column: column)
    }

    private mutating func failQuoted(column: Int) {
        report(.unterminatedQuote)
        position = lineEnd
        emit(.invalid, column: column)
    }

    /// After a closing quote: the line end, whitespace, `:`, or (in flow) `,`, `]`, `}`.
    private mutating func finishQuoted(_ text: [UInt8], style: ManifestScalarStyle, isValid: Bool, column: Int) {
        let isWellEnded = isSeparator(at: position) || bytes[position] == Byte.colon
            || (flowDepth > 0 && isFlowIndicator(bytes[position]))
        guard isWellEnded else {
            if isValid { report(.unexpectedContent) }
            skipWord()
            emit(.invalid, column: column)
            return
        }
        lastQuotedEnd = position
        emit(isValid ? .scalar(String(decoding: text, as: UTF8.self), style) : .invalid, column: column)
    }

    /// Moves past the current byte and the rest of its word (up to whitespace, a flow indicator
    /// or a `:` that ends a key): an anchor, alias or tag name, or a run of unexpected text.
    private mutating func skipWord() {
        position += 1
        while position < lineEnd, !isInlineSpace(bytes[position]), !isFlowIndicator(bytes[position]) {
            if bytes[position] == Byte.colon, endsKey(at: position) { return }
            position += 1
        }
    }

    // MARK: - Helpers

    private mutating func emitIndicator(_ kind: ManifestToken.Kind, column: Int) {
        emit(kind, column: column)
        position += 1
    }

    private mutating func emit(_ kind: ManifestToken.Kind, column: Int) {
        tokens.append(ManifestToken(kind: kind, line: lineNumber, column: column, startsLine: !tokenOnLine))
        tokenOnLine = true
    }

    private mutating func report(_ kind: ManifestIssue.Kind) {
        issues.append(ManifestIssue(line: lineNumber, kind: kind, key: nil))
    }

    /// True at the line end or before a space or tab.
    private func isSeparator(at index: Int) -> Bool {
        index >= lineEnd || isInlineSpace(bytes[index])
    }

    private func isInlineSpace(_ byte: UInt8) -> Bool {
        byte == Byte.space || byte == Byte.tab
    }

    private func isFlowIndicator(_ byte: UInt8) -> Bool {
        byte == Byte.comma || byte == Byte.openBracket || byte == Byte.closeBracket
            || byte == Byte.openBrace || byte == Byte.closeBrace
    }
}
