/// A node of the manifest's YAML tree: a value and the 1-based line it starts on.
struct ManifestNode: Sendable, Hashable {
    enum Value: Sendable, Hashable {
        case scalar(String, ManifestScalarStyle)
        /// Entries in document order, without duplicate keys.
        case mapping([ManifestEntry])
        case sequence([ManifestNode])
        /// An empty value (`key:` with nothing after it or under it).
        case null
        /// A value the reader already reported. The schema mapper skips it silently.
        case invalid
    }

    let value: Value
    let line: Int
}

/// One `key: value` pair of a mapping node.
struct ManifestEntry: Sendable, Hashable {
    let key: String
    let keyLine: Int
    let value: ManifestNode
}

/// What ``ManifestReader`` read.
struct ManifestReadResult: Sendable, Hashable {
    /// The document's root node, or nil when the text holds no content.
    let root: ManifestNode?
    /// Reader issues, in the order they were found.
    let issues: [ManifestIssue]
    /// True when an unclosed flow collection swallowed the rest of the file, so fields after
    /// it are not missing, just unread.
    let isTruncated: Bool
}

/// The YAML-subset reader: tokenizes manifest text and builds the node tree.
enum ManifestReader {
    static func read(_ text: String) -> ManifestReadResult {
        var tokenizer = ManifestTokenizer(text: text)
        tokenizer.run()
        var builder = ManifestTreeBuilder(tokens: tokenizer.tokens)
        let root = builder.build()
        return ManifestReadResult(root: root, issues: tokenizer.issues + builder.issues, isTruncated: builder.isTruncated)
    }
}

/// Builds a ``ManifestNode`` tree from tokens by recursive descent.
///
/// Block structure follows token columns: a block mapping or sequence is the run of entries
/// that start a line at its column; deeper lines belong to the entry above them. A sequence may
/// sit at the same column as the key that owns it (`key:` then `- item`). Flow collections may
/// span lines and ignore columns. Each collection checks the nesting limit before descending,
/// so recursion is bounded by ``EnvToolsLimits/maxManifestNestingDepth``. On an error the
/// builder reports once and skips the entry (its line and the lines nested under it, or the
/// rest of the broken flow collection), so one mistake does not cascade.
struct ManifestTreeBuilder {
    private let tokens: [ManifestToken]
    private var index = 0
    /// Line of the last consumed token.
    private var lastLine = 1
    private(set) var issues: [ManifestIssue] = []
    /// True when a flow collection never closed, so the rest of the file was swallowed by it.
    private(set) var isTruncated = false

    init(tokens: [ManifestToken]) {
        self.tokens = tokens
    }

    mutating func build() -> ManifestNode? {
        guard let first = peek else { return nil }
        let root = parseNode(column: first.column, depth: 1)
        if let leftover = peek {
            let indentedBack = leftover.startsLine && leftover.column < first.column
            report(indentedBack ? .invalidIndentation : .unexpectedContent, line: leftover.line)
            index = tokens.count
        }
        return root
    }

    // MARK: - Block nodes

    /// A node whose first token is at `column` (the start of a line, or after `- `).
    private mutating func parseNode(column: Int, depth: Int) -> ManifestNode {
        guard let token = peek else { return ManifestNode(value: .null, line: lastLine) }
        switch token.kind {
        case .dash:
            return parseBlockSequence(column: column, depth: depth, isInline: false, sharesColumnWithKey: false)
        case .scalar, .invalid:
            if isColon(at: index + 1, line: token.line) {
                return parseBlockMapping(column: column, depth: depth, isInline: false)
            }
            // More lines at this column: the node is a collection whose first line is broken.
            if index + 1 < tokens.count, tokens[index + 1].startsLine, tokens[index + 1].column == column {
                if tokens[index + 1].kind == .dash {
                    return parseBlockSequence(column: column, depth: depth, isInline: false, sharesColumnWithKey: false)
                }
                if isColon(at: index + 2, line: tokens[index + 1].line) {
                    return parseBlockMapping(column: column, depth: depth, isInline: false)
                }
            }
            advance()
            ensureLineEnds(column: column)
            return scalarNode(token)
        case .openBracket, .openBrace:
            if flowIsKey(at: index) {
                return parseBlockMapping(column: column, depth: depth, isInline: false)
            }
            return parseFlowValue(column: column, depth: depth)
        case .colon:
            // An empty key: the mapping reports it and reads its other entries.
            return parseBlockMapping(column: column, depth: depth, isInline: false)
        case .comma, .closeBracket, .closeBrace:
            report(.unexpectedContent, line: token.line)
            skipEntry(fromLine: token.line, column: column)
            return ManifestNode(value: .invalid, line: token.line)
        }
    }

    private mutating func parseBlockMapping(column: Int, depth: Int, isInline: Bool) -> ManifestNode {
        let startLine = peek?.line ?? lastLine
        guard depth <= EnvToolsLimits.maxManifestNestingDepth else {
            report(.nestingTooDeep(limit: EnvToolsLimits.maxManifestNestingDepth), line: startLine)
            skipBlock(column: column, isSequence: false)
            return ManifestNode(value: .invalid, line: startLine)
        }
        var entries: [ManifestEntry] = []
        var keyLines: [String: Int] = [:]
        var isFirst = true
        while let token = peek {
            let startsEntry = token.startsLine || (isFirst && isInline)
            guard startsEntry else {
                report(.unexpectedContent, line: token.line)
                skipEntry(fromLine: token.line, column: column)
                continue
            }
            if token.column < column { break }
            if token.column > column {
                report(.invalidIndentation, line: token.line)
                skipEntry(fromLine: token.line, column: column)
                continue
            }
            isFirst = false
            let hasColon = isColon(at: index + 1, line: token.line)
            switch token.kind {
            case .scalar(let key, _) where hasColon:
                advance(count: 2)
                let value = parseMappingValue(keyColumn: column, keyLine: token.line, depth: depth + 1)
                if let previous = keyLines[key] {
                    report(.duplicateKey(previousLine: previous), line: token.line, key: key)
                } else {
                    keyLines[key] = token.line
                    entries.append(ManifestEntry(key: key, keyLine: token.line, value: value))
                }
            case .invalid where hasColon:
                // The key was already reported (an alias or broken quote): read and drop it.
                advance(count: 2)
                _ = parseMappingValue(keyColumn: column, keyLine: token.line, depth: depth + 1)
            case .invalid:
                skipEntry(fromLine: token.line, column: column)
            case .scalar:
                report(.missingColon, line: token.line)
                skipEntry(fromLine: token.line, column: column)
            case .dash:
                report(.mixedCollection, line: token.line)
                skipEntry(fromLine: token.line, column: column)
            case .openBracket, .openBrace, .colon:
                report(.nonScalarKey, line: token.line)
                skipEntry(fromLine: token.line, column: column)
            case .comma, .closeBracket, .closeBrace:
                report(.unexpectedContent, line: token.line)
                skipEntry(fromLine: token.line, column: column)
            }
        }
        return ManifestNode(value: .mapping(entries), line: startLine)
    }

    /// The value after `key:` on `keyLine`: on the same line, or on deeper lines below it.
    private mutating func parseMappingValue(keyColumn: Int, keyLine: Int, depth: Int) -> ManifestNode {
        guard let token = peek else { return ManifestNode(value: .null, line: keyLine) }
        if token.line == keyLine {
            switch token.kind {
            case .scalar, .invalid:
                advance()
                if let next = peek, next.line == keyLine, next.kind == .colon {
                    // `a: b: c`: a mapping cannot start on its parent key's line.
                    report(.unexpectedContent, line: keyLine)
                    skipEntry(fromLine: keyLine, column: keyColumn)
                    return ManifestNode(value: .invalid, line: keyLine)
                }
                ensureLineEnds(column: keyColumn)
                return scalarNode(token)
            case .openBracket, .openBrace:
                return parseFlowValue(column: keyColumn, depth: depth)
            case .dash, .colon, .comma, .closeBracket, .closeBrace:
                report(.unexpectedContent, line: keyLine)
                skipEntry(fromLine: keyLine, column: keyColumn)
                return ManifestNode(value: .invalid, line: keyLine)
            }
        }
        if token.startsLine, token.column > keyColumn {
            return parseNode(column: token.column, depth: depth)
        }
        if token.startsLine, token.column == keyColumn, token.kind == .dash {
            return parseBlockSequence(column: keyColumn, depth: depth, isInline: false, sharesColumnWithKey: true)
        }
        return ManifestNode(value: .null, line: keyLine)
    }

    /// - Parameter sharesColumnWithKey: the sequence is the value of a key at the same column,
    ///   so a non-dash line at that column is the key's next sibling, not an error.
    private mutating func parseBlockSequence(
        column: Int,
        depth: Int,
        isInline: Bool,
        sharesColumnWithKey: Bool
    ) -> ManifestNode {
        let startLine = peek?.line ?? lastLine
        guard depth <= EnvToolsLimits.maxManifestNestingDepth else {
            report(.nestingTooDeep(limit: EnvToolsLimits.maxManifestNestingDepth), line: startLine)
            skipBlock(column: column, isSequence: true)
            return ManifestNode(value: .invalid, line: startLine)
        }
        var items: [ManifestNode] = []
        var isFirst = true
        while let token = peek {
            let startsItem = token.startsLine || (isFirst && isInline)
            guard startsItem else {
                report(.unexpectedContent, line: token.line)
                skipEntry(fromLine: token.line, column: column)
                continue
            }
            if token.column < column { break }
            if token.column > column {
                report(.invalidIndentation, line: token.line)
                skipEntry(fromLine: token.line, column: column)
                continue
            }
            guard token.kind == .dash else {
                if sharesColumnWithKey { break }
                report(.mixedCollection, line: token.line)
                skipEntry(fromLine: token.line, column: column)
                continue
            }
            isFirst = false
            advance()
            items.append(parseSequenceItem(dashColumn: column, dashLine: token.line, depth: depth + 1))
        }
        return ManifestNode(value: .sequence(items), line: startLine)
    }

    /// The item after `- ` on `dashLine`: on the same line (a scalar, a flow collection, a
    /// compact `- key: value` mapping or `- - item` sequence), or on deeper lines below it.
    private mutating func parseSequenceItem(dashColumn: Int, dashLine: Int, depth: Int) -> ManifestNode {
        guard let token = peek else { return ManifestNode(value: .null, line: dashLine) }
        if token.line == dashLine {
            switch token.kind {
            case .scalar, .invalid:
                if isColon(at: index + 1, line: dashLine) {
                    return parseBlockMapping(column: token.column, depth: depth, isInline: true)
                }
                advance()
                ensureLineEnds(column: dashColumn)
                return scalarNode(token)
            case .dash:
                return parseBlockSequence(column: token.column, depth: depth, isInline: true, sharesColumnWithKey: false)
            case .openBracket, .openBrace:
                if flowIsKey(at: index) {
                    return parseBlockMapping(column: token.column, depth: depth, isInline: true)
                }
                return parseFlowValue(column: dashColumn, depth: depth)
            case .colon:
                report(.nonScalarKey, line: dashLine)
                skipEntry(fromLine: dashLine, column: dashColumn)
                return ManifestNode(value: .invalid, line: dashLine)
            case .comma, .closeBracket, .closeBrace:
                report(.unexpectedContent, line: dashLine)
                skipEntry(fromLine: dashLine, column: dashColumn)
                return ManifestNode(value: .invalid, line: dashLine)
            }
        }
        if token.startsLine, token.column > dashColumn {
            return parseNode(column: token.column, depth: depth)
        }
        return ManifestNode(value: .null, line: dashLine)
    }

    /// A flow collection used as a block value; nothing may follow it on its closing line.
    private mutating func parseFlowValue(column: Int, depth: Int) -> ManifestNode {
        let node = parseFlowCollection(depth: depth)
        ensureLineEnds(column: column)
        return node
    }

    /// True when the flow collection opening at `start` is followed by `:` on the line it
    /// closes on, so it was written as a key (`[a]: b`).
    private func flowIsKey(at start: Int) -> Bool {
        var flowDepth = 0
        var position = start
        while position < tokens.count {
            let token = tokens[position]
            trackFlowDepth(token, depth: &flowDepth)
            position += 1
            if flowDepth == 0 { return isColon(at: position, line: token.line) }
        }
        return false
    }

    // MARK: - Flow nodes

    /// `[ ... ]` or `{ ... }`; the current token is the opening bracket.
    private mutating func parseFlowCollection(depth: Int) -> ManifestNode {
        let open = advance()
        guard depth <= EnvToolsLimits.maxManifestNestingDepth else {
            report(.nestingTooDeep(limit: EnvToolsLimits.maxManifestNestingDepth), line: open.line)
            if !skipFlowRemainder() { _ = unterminated(openLine: open.line) }
            return ManifestNode(value: .invalid, line: open.line)
        }
        if open.kind == .openBracket {
            return parseFlowSequence(openLine: open.line, depth: depth)
        }
        return parseFlowMapping(openLine: open.line, depth: depth)
    }

    private mutating func parseFlowSequence(openLine: Int, depth: Int) -> ManifestNode {
        var items: [ManifestNode] = []
        while true {
            guard let token = peek else { return unterminated(openLine: openLine) }
            if token.kind == .closeBracket {
                advance()
                return ManifestNode(value: .sequence(items), line: openLine)
            }
            guard let item = parseFlowItem(depth: depth + 1, openLine: openLine) else {
                return ManifestNode(value: .invalid, line: openLine)
            }
            items.append(item)
            guard let separator = peek else { return unterminated(openLine: openLine) }
            switch separator.kind {
            case .comma:
                advance()
            case .closeBracket:
                advance()
                return ManifestNode(value: .sequence(items), line: openLine)
            default:
                return failFlow(.unexpectedContent, line: separator.line, openLine: openLine)
            }
        }
    }

    private mutating func parseFlowMapping(openLine: Int, depth: Int) -> ManifestNode {
        var entries: [ManifestEntry] = []
        var keyLines: [String: Int] = [:]
        while true {
            guard let token = peek else { return unterminated(openLine: openLine) }
            let key: String?
            switch token.kind {
            case .closeBrace:
                advance()
                return ManifestNode(value: .mapping(entries), line: openLine)
            case .scalar(let text, _):
                key = text
            case .invalid:
                key = nil
            case .openBracket, .openBrace:
                return failFlow(.nonScalarKey, line: token.line, openLine: openLine)
            case .colon, .dash, .comma, .closeBracket:
                return failFlow(.unexpectedContent, line: token.line, openLine: openLine)
            }
            advance()
            guard let next = peek else { return unterminated(openLine: openLine) }
            var value: ManifestNode?
            switch next.kind {
            case .colon:
                advance()
                guard let after = peek else { return unterminated(openLine: openLine) }
                if after.kind == .comma || after.kind == .closeBrace {
                    value = ManifestNode(value: .null, line: next.line)
                } else {
                    guard let item = parseFlowItem(depth: depth + 1, openLine: openLine) else {
                        return ManifestNode(value: .invalid, line: openLine)
                    }
                    value = item
                }
            case .comma, .closeBrace:
                // `{ a, b }`: keys without values.
                if key != nil { report(.missingColon, line: token.line) }
            default:
                return failFlow(.unexpectedContent, line: next.line, openLine: openLine)
            }
            if let key, let value {
                if let previous = keyLines[key] {
                    report(.duplicateKey(previousLine: previous), line: token.line, key: key)
                } else {
                    keyLines[key] = token.line
                    entries.append(ManifestEntry(key: key, keyLine: token.line, value: value))
                }
            }
            guard let separator = peek else { return unterminated(openLine: openLine) }
            switch separator.kind {
            case .comma:
                advance()
            case .closeBrace:
                advance()
                return ManifestNode(value: .mapping(entries), line: openLine)
            default:
                return failFlow(.unexpectedContent, line: separator.line, openLine: openLine)
            }
        }
    }

    /// A scalar or nested collection inside the flow collection opened on `openLine`. Nil after
    /// an error, once the rest of that collection has been skipped.
    private mutating func parseFlowItem(depth: Int, openLine: Int) -> ManifestNode? {
        guard let token = peek else { return nil }
        switch token.kind {
        case .scalar, .invalid:
            advance()
            return scalarNode(token)
        case .openBracket, .openBrace:
            return parseFlowCollection(depth: depth)
        case .colon, .dash, .comma, .closeBracket, .closeBrace:
            _ = failFlow(.unexpectedContent, line: token.line, openLine: openLine)
            return nil
        }
    }

    private mutating func unterminated(openLine: Int) -> ManifestNode {
        // The rest of the file belongs to the first unclosed collection: report it once.
        if !isTruncated {
            isTruncated = true
            report(.unterminatedFlowCollection, line: openLine)
        }
        return ManifestNode(value: .invalid, line: openLine)
    }

    // MARK: - Recovery

    /// Reports and skips anything left on the line of the last consumed token.
    private mutating func ensureLineEnds(column: Int) {
        guard let token = peek, token.line == lastLine else { return }
        report(.unexpectedContent, line: token.line)
        skipEntry(fromLine: token.line, column: column)
    }

    /// Skips the rest of `line` (with any flow collection opened on it, to its end), then every
    /// later line that starts deeper than `column`.
    private mutating func skipEntry(fromLine line: Int, column: Int) {
        var flowDepth = 0
        while let token = peek {
            if flowDepth == 0, token.line != line, token.startsLine, token.column <= column { return }
            trackFlowDepth(token, depth: &flowDepth)
            advance()
        }
    }

    /// Skips a whole block collection at `column` (nesting too deep). A sequence ends at a
    /// non-dash line at its own column, a mapping only at a shallower line.
    private mutating func skipBlock(column: Int, isSequence: Bool) {
        var flowDepth = 0
        var isFirst = true
        while let token = peek {
            if !isFirst, flowDepth == 0, token.startsLine {
                if token.column < column { return }
                if isSequence, token.column == column, token.kind != .dash { return }
            }
            isFirst = false
            trackFlowDepth(token, depth: &flowDepth)
            advance()
        }
    }

    /// After an error at `line` inside the flow collection opened on `openLine`: skips the rest
    /// of the collection and reports `kind`, or, when the collection never closes, only that
    /// (the likelier cause, and the error token was just the first line it swallowed).
    private mutating func failFlow(_ kind: ManifestIssue.Kind, line: Int, openLine: Int) -> ManifestNode {
        if skipFlowRemainder() {
            report(kind, line: line)
        } else {
            _ = unterminated(openLine: openLine)
        }
        return ManifestNode(value: .invalid, line: openLine)
    }

    /// Skips to the end of the flow collection whose opening bracket was consumed (any closing
    /// bracket counts, so a mismatched one ends it too). False when the file ends first.
    private mutating func skipFlowRemainder() -> Bool {
        var flowDepth = 1
        while let token = peek {
            advance()
            trackFlowDepth(token, depth: &flowDepth)
            if flowDepth == 0 { return true }
        }
        return false
    }

    private func trackFlowDepth(_ token: ManifestToken, depth: inout Int) {
        switch token.kind {
        case .openBracket, .openBrace:
            depth += 1
        case .closeBracket, .closeBrace:
            depth = max(0, depth - 1)
        default:
            break
        }
    }

    // MARK: - Helpers

    private var peek: ManifestToken? {
        index < tokens.count ? tokens[index] : nil
    }

    /// True when the token at `position` is a `:` on `line`.
    private func isColon(at position: Int, line: Int) -> Bool {
        position < tokens.count && tokens[position].kind == .colon && tokens[position].line == line
    }

    @discardableResult
    private mutating func advance() -> ManifestToken {
        let token = tokens[index]
        index += 1
        lastLine = token.line
        return token
    }

    private mutating func advance(count: Int) {
        for _ in 0..<count where index < tokens.count {
            advance()
        }
    }

    private func scalarNode(_ token: ManifestToken) -> ManifestNode {
        switch token.kind {
        case .scalar(let text, let style):
            ManifestNode(value: .scalar(text, style), line: token.line)
        default:
            ManifestNode(value: .invalid, line: token.line)
        }
    }

    private mutating func report(_ kind: ManifestIssue.Kind, line: Int, key: String? = nil) {
        issues.append(.sanitized(line: line, kind: kind, key: key))
    }
}
