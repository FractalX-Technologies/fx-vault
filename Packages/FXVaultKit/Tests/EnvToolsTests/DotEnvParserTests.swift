import Foundation
import Testing
import VaultCore
@testable import EnvTools

/// One parser table case: input text, expected entries (key, value, line) and issues.
struct ParserCase: Sendable, CustomTestStringConvertible {
    let name: String
    let input: String
    let entries: [ParsedPair]
    let issues: [EnvParseIssue]

    init(_ name: String, _ input: String, _ entries: [ParsedPair], issues: [EnvParseIssue] = []) {
        self.name = name
        self.input = input
        self.entries = entries
        self.issues = issues
    }

    var testDescription: String { name }
}

private func pair(_ key: String, _ value: String, _ line: Int) -> ParsedPair {
    ParsedPair(key, value, line: line)
}

private func issue(_ line: Int, _ kind: EnvParseIssue.Kind, _ key: String?) -> EnvParseIssue {
    EnvParseIssue(line: line, kind: kind, key: key)
}

@Suite("DotEnvParser")
struct DotEnvParserTests {
    static let cases: [ParserCase] = [
        // Basics
        ParserCase("simple pair", "A=1", [pair("A", "1", 1)]),
        ParserCase("trailing newline", "A=1\n", [pair("A", "1", 1)]),
        ParserCase("several lines", "A=1\nB=2\nC=3\n", [pair("A", "1", 1), pair("B", "2", 2), pair("C", "3", 3)]),
        ParserCase("empty input", "", []),
        ParserCase("blank lines", "\n\nA=1\n\n", [pair("A", "1", 3)]),
        ParserCase("whitespace-only lines", "  \t\nA=1\n \n", [pair("A", "1", 2)]),
        ParserCase("only comments", "# a\n# b\n", []),
        ParserCase("full-line comment", "# comment\nA=1", [pair("A", "1", 2)]),
        ParserCase("indented comment", "   # c\nA=1", [pair("A", "1", 2)]),
        ParserCase("lowercase and dotted keys kept as written", "app.name=x", [pair("app.name", "x", 1)]),

        // export
        ParserCase("export prefix", "export A=1", [pair("A", "1", 1)]),
        ParserCase("export with tab and spaces", "export\t  A=1", [pair("A", "1", 1)]),
        ParserCase("key named export", "export=1", [pair("export", "1", 1)]),
        ParserCase("export without assignment", "export A", [], issues: [issue(1, .missingEquals, nil)]),

        // Whitespace around keys and values
        ParserCase("spaces around equals", "A = 1", [pair("A", "1", 1)]),
        ParserCase("indented key", "   A=1", [pair("A", "1", 1)]),
        ParserCase("tab before value", "A=\tvalue", [pair("A", "value", 1)]),
        ParserCase("empty value", "A=", [pair("A", "", 1)]),
        ParserCase("empty value with spaces", "A=   ", [pair("A", "", 1)]),
        ParserCase("inner spaces kept", "A=hello world", [pair("A", "hello world", 1)]),
        ParserCase("trailing spaces trimmed", "A=hello   \t", [pair("A", "hello", 1)]),
        ParserCase("equals in value", "A=b=c", [pair("A", "b=c", 1)]),
        ParserCase("value starting with equals", "A==c", [pair("A", "=c", 1)]),

        // Inline comments (unquoted values only, after whitespace)
        ParserCase("inline comment after space", "A=1 # c", [pair("A", "1", 1)]),
        ParserCase("inline comment after tab", "A=1\t# c", [pair("A", "1", 1)]),
        ParserCase("hash without whitespace is kept", "A=a#b", [pair("A", "a#b", 1)]),
        ParserCase("value starting with hash", "A=#abc", [pair("A", "#abc", 1)]),
        ParserCase("only a comment after equals", "A= # c", [pair("A", "", 1)]),
        ParserCase(
            "URL with fragment",
            "A=https://x.test/a?b=c&d=e#frag",
            [pair("A", "https://x.test/a?b=c&d=e#frag", 1)]
        ),
        ParserCase("quote in the middle of an unquoted value", "A=ab\"c", [pair("A", "ab\"c", 1)]),

        // Single quotes
        ParserCase("single-quoted literal", "A='a b # c'", [pair("A", "a b # c", 1)]),
        ParserCase("single quotes ignore escapes", #"A='a\nb'"#, [pair("A", #"a\nb"#, 1)]),
        ParserCase("single quotes do not warn on ${", "A='${X}'", [pair("A", "${X}", 1)]),
        ParserCase("single-quoted multi-line", "A='l1\nl2'\nB=2", [pair("A", "l1\nl2", 1), pair("B", "2", 3)]),
        ParserCase("double quote inside single", #"A='say "x"'"#, [pair("A", #"say "x""#, 1)]),
        ParserCase("empty quotes", "A=\"\"\nB=''", [pair("A", "", 1), pair("B", "", 2)]),

        // Double quotes
        ParserCase("double-quoted escapes", #"A="a\nb\tc\rd""#, [pair("A", "a\nb\tc\rd", 1)]),
        ParserCase("escaped quote and backslash", #"A="say \"hi\" \\ ok""#, [pair("A", #"say "hi" \ ok"#, 1)]),
        ParserCase("escaped dollar suppresses expansion", #"A="\${X}""#, [pair("A", "${X}", 1)]),
        ParserCase("double-quoted multi-line", "A=\"l1\nl2\"\nB=2", [pair("A", "l1\nl2", 1), pair("B", "2", 3)]),
        ParserCase("hash inside double quotes", #"A="a # b" # c"#, [pair("A", "a # b", 1)]),
        ParserCase("comment right after closing quote", ##"A="a"# c"##, [pair("A", "a", 1)]),
        ParserCase("spaces after closing quote", "A=\"x\"   \nB=1", [pair("A", "x", 1), pair("B", "1", 2)]),
        ParserCase("single quote inside double", #"A="it's""#, [pair("A", "it's", 1)]),

        // Line endings and encoding
        ParserCase("CRLF", "A=1\r\nB=2\r\n", [pair("A", "1", 1), pair("B", "2", 2)]),
        ParserCase("CRLF inside quotes becomes LF", "A=\"l1\r\nl2\"\r\nB=2", [pair("A", "l1\nl2", 1), pair("B", "2", 3)]),
        ParserCase("CRLF with inline comment", "A=1 # c\r\nB=2", [pair("A", "1", 1), pair("B", "2", 2)]),
        ParserCase("UTF-8 BOM", "\u{FEFF}A=1", [pair("A", "1", 1)]),
        ParserCase("lone CR is kept", "A=a\rb\n", [pair("A", "a\rb", 1)]),
        ParserCase("unicode value", "A=héllo 漢字 🙂", [pair("A", "héllo 漢字 🙂", 1)]),
        ParserCase("unicode in double quotes", #"A="ñ\nü""#, [pair("A", "ñ\nü", 1)]),

        // Variable expansion is not supported
        ParserCase(
            "expansion in unquoted value warns",
            "A=${B}",
            [pair("A", "${B}", 1)],
            issues: [issue(1, .variableExpansionNotSupported, "A")]
        ),
        ParserCase(
            "expansion in double quotes warns",
            #"A="x ${B} y""#,
            [pair("A", "x ${B} y", 1)],
            issues: [issue(1, .variableExpansionNotSupported, "A")]
        ),
        ParserCase("dollar without brace does not warn", "A=$B", [pair("A", "$B", 1)]),

        // Duplicates: last wins, first position kept
        ParserCase(
            "duplicate key, last wins",
            "A=1\nB=2\nA=3",
            [pair("A", "3", 3), pair("B", "2", 2)],
            issues: [issue(3, .duplicateKey(previousLine: 1), "A")]
        ),
        ParserCase(
            "key repeated three times",
            "A=1\nA=2\nA=3",
            [pair("A", "3", 3)],
            issues: [issue(2, .duplicateKey(previousLine: 1), "A"), issue(3, .duplicateKey(previousLine: 2), "A")]
        ),

        // Errors skip the line
        ParserCase(
            "missing equals",
            "JUSTAKEY\nA=1",
            [pair("A", "1", 2)],
            issues: [issue(1, .missingEquals, nil)]
        ),
        ParserCase("space inside key", "MY KEY=1", [], issues: [issue(1, .missingEquals, nil)]),
        ParserCase("empty key", "=value\nA=1", [pair("A", "1", 2)], issues: [issue(1, .emptyKey, nil)]),
        ParserCase("control character in key", "A\u{01}B=1", [], issues: [issue(1, .invalidKey, nil)]),
        ParserCase(
            "unterminated double quote resumes on the next line",
            "A=\"abc\nB=2",
            [pair("B", "2", 2)],
            issues: [issue(1, .unterminatedQuote, "A")]
        ),
        ParserCase(
            "unterminated single quote resumes on the next line",
            "A='abc\nB=2\nC=3",
            [pair("B", "2", 2), pair("C", "3", 3)],
            issues: [issue(1, .unterminatedQuote, "A")]
        ),
        ParserCase(
            "characters after closing quote",
            "A=\"abc\"def\nB=2",
            [pair("B", "2", 2)],
            issues: [issue(1, .unexpectedCharactersAfterQuote, "A")]
        ),
        ParserCase(
            "unknown escape is kept with a warning",
            #"A="C:\path""#,
            [pair("A", #"C:\path"#, 1)],
            issues: [issue(1, .unknownEscapeSequence, "A")]
        ),
        ParserCase(
            "backslash before a line break is kept",
            "A=\"a\\\nb\"",
            [pair("A", "a\\\nb", 1)],
            issues: [issue(1, .unknownEscapeSequence, "A")]
        ),
        ParserCase(
            "issues are ordered by line",
            "X\nA=${B}\n=1",
            [pair("A", "${B}", 2)],
            issues: [
                issue(1, .missingEquals, nil),
                issue(2, .variableExpansionNotSupported, "A"),
                issue(3, .emptyKey, nil),
            ]
        ),
    ]

    // MARK: - Unquoted multi-line PEM values

    /// Synthetic key material (not a real key). Body lines end in `==`, `=` or nothing.
    static let pemBodyLines = [
        "FXVFIXTUREpemBODYlineONEabc+def/ghi==",
        "FXVFIXTUREpemBODYlineTWO=",
        "FXVFIXTUREpemBODYlineTHREE",
    ]

    @Test("unquoted PEM is skipped up to its END line", arguments: pemBodyLines)
    func unquotedPEMIsSkipped(_ bodyLine: String) throws {
        let text = """
        A=1
        JWT_KEY=-----BEGIN FXV FIXTURE KEY-----
        FXVFIXTUREpemBODYfirstLINE
        \(bodyLine)
        -----END FXV FIXTURE KEY-----
        B=2
        """
        let result = try DotEnvParser.parse(text)
        #expect(result.pairsWithLines == [ParsedPair("A", "1", line: 1), ParsedPair("B", "2", line: 6)])
        #expect(result.issues == [EnvParseIssue(line: 2, kind: .unquotedMultilineValue, key: "JWT_KEY")])
        #expect(result.hasErrors)
        let body = bodyLine.prefix { $0 != "=" }
        #expect(result.issues.allSatisfy { $0.key.map { !$0.contains(body) } ?? true })
    }

    @Test func unquotedPEMWithCRLFAndIndentedEndLine() throws {
        let text = "K=-----BEGIN CERTIFICATE-----\r\nFXVFIXTURE+abc==\r\n  -----END CERTIFICATE-----\r\nB=2"
        let result = try DotEnvParser.parse(text)
        #expect(result.pairsWithLines == [ParsedPair("B", "2", line: 4)])
        #expect(result.issues == [EnvParseIssue(line: 1, kind: .unquotedMultilineValue, key: "K")])
    }

    @Test func unterminatedUnquotedPEMSkipsToTheEnd() throws {
        let result = try DotEnvParser.parse("A=1\nK=-----BEGIN FXV FIXTURE KEY-----\nFXVFIXTURE+abc==\nNEXT=after")
        #expect(result.pairsWithLines == [ParsedPair("A", "1", line: 1)])
        #expect(result.issues == [EnvParseIssue(line: 2, kind: .unquotedMultilineValue, key: "K")])
    }

    @Test func singleLinePEMAndQuotedPEMAreKept() throws {
        let oneLine = "-----BEGIN FXV FIXTURE-----AAAA-----END FXV FIXTURE-----"
        let text = "A=\(oneLine)\nB=\"-----BEGIN FXV FIXTURE-----\nAAAA==\n-----END FXV FIXTURE-----\"\nC=3"
        let result = try DotEnvParser.parse(text)
        #expect(result.pairsWithLines == [
            ParsedPair("A", oneLine, line: 1),
            ParsedPair("B", "-----BEGIN FXV FIXTURE-----\nAAAA==\n-----END FXV FIXTURE-----", line: 2),
            ParsedPair("C", "3", line: 5),
        ])
        #expect(result.issues.isEmpty)
    }

    @Test func missingEqualsNeverEchoesTheLine() throws {
        let result = try DotEnvParser.parse("ghp_FXV_FIXTURE_TOKEN\nA=1")
        #expect(result.issues == [EnvParseIssue(line: 1, kind: .missingEquals, key: nil)])
    }

    @Test("table", arguments: cases)
    func table(_ testCase: ParserCase) throws {
        let result = try DotEnvParser.parse(testCase.input)
        #expect(result.pairsWithLines == testCase.entries)
        #expect(result.issues == testCase.issues)
    }

    @Test func tableHasAtLeastFortyCases() {
        #expect(Self.cases.count >= 40)
    }

    @Test func invalidUTF8ValueIsSkipped() throws {
        let bytes = Array("A=".utf8) + [0xFF, 0xFE] + Array("\nB=1".utf8)
        let result = try DotEnvParser.parse(SecretBytes(copying: bytes))
        #expect(result.pairsWithLines == [ParsedPair("B", "1", line: 2)])
        #expect(result.issues == [EnvParseIssue(line: 1, kind: .invalidEncoding, key: "A")])
        #expect(result.hasErrors)
    }

    @Test func invalidUTF8KeyIsSkipped() throws {
        let bytes: [UInt8] = [0xC3, 0x28] + Array("=1\nB=2".utf8)
        let result = try DotEnvParser.parse(SecretBytes(copying: bytes))
        #expect(result.pairs == [ParsedPair("B", "2")])
        #expect(result.issues == [EnvParseIssue(line: 1, kind: .invalidKey, key: nil)])
    }

    @Test func fileLargerThanTheLimitIsRejected() {
        let contents = SecretBytes(count: EnvToolsLimits.maxEnvFileBytes + 1)
        #expect(throws: DotEnvParseError.fileTooLarge(limit: EnvToolsLimits.maxEnvFileBytes)) {
            try DotEnvParser.parse(contents)
        }
    }

    @Test func severities() {
        #expect(EnvParseIssue(line: 1, kind: .duplicateKey(previousLine: 0), key: "A").severity == .warning)
        #expect(EnvParseIssue(line: 1, kind: .variableExpansionNotSupported, key: "A").severity == .warning)
        #expect(EnvParseIssue(line: 1, kind: .unknownEscapeSequence, key: "A").severity == .warning)
        #expect(EnvParseIssue(line: 1, kind: .unterminatedQuote, key: "A").severity == .error)
        #expect(EnvParseIssue(line: 1, kind: .missingEquals, key: nil).severity == .error)
        #expect(EnvParseIssue(line: 1, kind: .unquotedMultilineValue, key: "A").severity == .error)
    }

    @Test func warningsDoNotCountAsErrors() throws {
        let result = try DotEnvParser.parse("A=${B}\nA=2")
        #expect(!result.hasErrors)
        #expect(result.issues(onLine: 2) == [EnvParseIssue(line: 2, kind: .duplicateKey(previousLine: 1), key: "A")])
    }

    @Test func parsedValuesAreRedactedWhenPrinted() throws {
        let result = try DotEnvParser.parse("TOKEN=visible-only-in-buffer")
        let entry = try #require(result.entries.first)
        #expect(!String(describing: entry).contains("visible-only-in-buffer"))
        #expect(!String(reflecting: entry).contains("visible-only-in-buffer"))
    }

    @Test func parsingDoesNotModifyTheInput() throws {
        let text = "A=\"x\\ny\"\n"
        let input = SecretBytes(utf8: text)
        _ = try DotEnvParser.parse(input)
        #expect(input.utf8String() == text)
        #expect(!input.isWiped)
    }
}
