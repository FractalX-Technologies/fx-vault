import Foundation
import Testing
import VaultCore
@testable import EnvTools

/// One reader table case: input text, the expected tree (nil for no content) and issues.
struct ReaderCase: Sendable, CustomTestStringConvertible {
    let name: String
    let input: String
    let tree: YAMLValue?
    let issues: [ManifestIssue]

    init(_ name: String, _ input: String, _ tree: YAMLValue?, issues: [ManifestIssue] = []) {
        self.name = name
        self.input = input
        self.tree = tree
        self.issues = issues
    }

    var testDescription: String { name }
}

@Suite("Manifest reader")
struct ManifestReaderTests {
    static let supported: [ReaderCase] = [
        // Empty documents
        ReaderCase("empty file", "", nil),
        ReaderCase("only comments", "# a\n  # b\n#c\n", nil),
        ReaderCase("only blank lines", "\n\n   \n\t\n", nil),
        ReaderCase("only a document start", "---\n", nil),

        // Block mappings
        ReaderCase("one pair", "a: b", m(("a", .plain("b")))),
        ReaderCase("pairs", "a: b\nc: d\n", m(("a", .plain("b")), ("c", .plain("d")))),
        ReaderCase(
            "nested mapping",
            "a:\n  b: c\n  d: e\nf: g",
            m(("a", m(("b", .plain("c")), ("d", .plain("e")))), ("f", .plain("g")))
        ),
        ReaderCase("indented root", "  a: b\n  c: d", m(("a", .plain("b")), ("c", .plain("d")))),
        ReaderCase("empty value", "a:\nb: c", m(("a", .null), ("b", .plain("c")))),
        ReaderCase("empty value at the end", "a: b\nc:", m(("a", .plain("b")), ("c", .null))),
        ReaderCase("value on the next line", "a:\n  b", m(("a", .plain("b")))),
        ReaderCase("tab after the colon", "a:\tb", m(("a", .plain("b")))),
        ReaderCase("spaces before the colon", "a   : b", m(("a", .plain("b")))),

        // Block sequences
        ReaderCase("indented sequence", "a:\n  - x\n  - y", m(("a", .seq([.plain("x"), .plain("y")])))),
        ReaderCase(
            "sequence at the key's column",
            "a:\n- x\n- y\nb: z",
            m(("a", .seq([.plain("x"), .plain("y")])), ("b", .plain("z")))
        ),
        ReaderCase("root sequence", "- a\n- b", .seq([.plain("a"), .plain("b")])),
        ReaderCase(
            "compact mappings in a sequence",
            "- a: 1\n  b: 2\n- c: 3",
            .seq([m(("a", .plain("1")), ("b", .plain("2"))), m(("c", .plain("3")))])
        ),
        ReaderCase(
            "compact nested sequence",
            "- - a\n  - b\n- c",
            .seq([.seq([.plain("a"), .plain("b")]), .plain("c")])
        ),
        ReaderCase("empty item", "- \n- b", .seq([.null, .plain("b")])),
        ReaderCase("item on the next line", "-\n  a: b", .seq([m(("a", .plain("b")))])),
        ReaderCase("dash without space is a scalar", "a: -x", m(("a", .plain("-x")))),

        // Flow collections
        ReaderCase("flow sequence", "a: [x, y, z]", m(("a", .seq([.plain("x"), .plain("y"), .plain("z")])))),
        ReaderCase("flow mapping", "a: { b: c, d: e }", m(("a", m(("b", .plain("c")), ("d", .plain("e")))))),
        ReaderCase(
            "nested flow",
            "a: { b: [c, d], e: { f: g } }",
            m(("a", m(("b", .seq([.plain("c"), .plain("d")])), ("e", m(("f", .plain("g")))))))
        ),
        ReaderCase("empty flow collections", "a: []\nb: {}", m(("a", .seq([])), ("b", .map([])))),
        ReaderCase("trailing comma", "a: [x, y, ]\nb: { c: d, }", m(("a", .seq([.plain("x"), .plain("y")])), ("b", m(("c", .plain("d")))))),
        ReaderCase("flow without spaces", "a: {b: c,d: [e,f]}", m(("a", m(("b", .plain("c")), ("d", .seq([.plain("e"), .plain("f")])))))),
        ReaderCase("JSON-style quoted keys", "{\"a\":1, \"b\": [2]}", m(("a", .plain("1")), ("b", .seq([.plain("2")])))),
        ReaderCase("flow value without a value", "{ a: , b: c }", m(("a", .null), ("b", .plain("c")))),
        ReaderCase(
            "multi-line flow collections",
            "a: { b: c,\n     d: [e,\n  f] }\ng: h",
            m(("a", m(("b", .plain("c")), ("d", .seq([.plain("e"), .plain("f")])))), ("g", .plain("h")))
        ),
        ReaderCase(
            "multi-line flow closing on its own line",
            "a: [\n  x,\n  y\n]\nb: c",
            m(("a", .seq([.plain("x"), .plain("y")])), ("b", .plain("c")))
        ),
        ReaderCase("flow sequence item", "- [a, b]\n- {c: d}", .seq([.seq([.plain("a"), .plain("b")]), m(("c", .plain("d")))])),
        ReaderCase("flow root", "[a, b]", .seq([.plain("a"), .plain("b")])),
        ReaderCase("flow mapping on the next line", "a:\n  { b: c }", m(("a", m(("b", .plain("c")))))),

        // Scalars
        ReaderCase("plain with spaces", "a: b c  d", m(("a", .plain("b c  d")))),
        ReaderCase("trailing spaces", "a: b   \nc: d  \t", m(("a", .plain("b")), ("c", .plain("d")))),
        ReaderCase("plain with a colon", "a: http://x.test/y:8", m(("a", .plain("http://x.test/y:8")))),
        ReaderCase("plain with a hash", "a: b#c", m(("a", .plain("b#c")))),
        ReaderCase("plain with brackets in block context", "a: b [c] {d}, e", m(("a", .plain("b [c] {d}, e")))),
        ReaderCase("booleans and integers stay text in the tree", "a: true\nb: 12", m(("a", .plain("true")), ("b", .plain("12")))),
        ReaderCase("unicode", "a: Producción 🙂", m(("a", .plain("Producción 🙂")))),
        ReaderCase("single-quoted", "a: 'it''s'", m(("a", .single("it's")))),
        ReaderCase("single quotes keep backslashes", #"a: 'x\ny'"#, m(("a", .single(#"x\ny"#)))),
        ReaderCase("empty quotes", "a: ''\nb: \"\"", m(("a", .single("")), ("b", .double("")))),
        ReaderCase(
            "double-quoted escapes",
            #"a: "q\"b\\n\nt\t""#,
            m(("a", .double("q\"b\\n\nt\t")))
        ),
        ReaderCase("quoted keys", "'my key': 1\n\"other\": 2", m(("my key", .plain("1")), ("other", .plain("2")))),
        ReaderCase("quoted true is text", "a: 'true'", m(("a", .single("true")))),
        ReaderCase("quotes in flow", "[ 'a, b', \"c]\" ]", .seq([.single("a, b"), .double("c]")])),

        // Comments
        ReaderCase("hash inside double quotes", "a: \"b # c\" # comment", m(("a", .double("b # c")))),
        ReaderCase("hash inside single quotes", "a: 'b # c' # d", m(("a", .single("b # c")))),
        ReaderCase("comment after a plain value", "a: b # c", m(("a", .plain("b")))),
        ReaderCase("comment after a key", "a: # c\n  b: c", m(("a", m(("b", .plain("c")))))),
        ReaderCase(
            "comments between entries",
            "# top\na: b\n  # indented\n# flush\nc: d # end",
            m(("a", .plain("b")), ("c", .plain("d")))
        ),
        ReaderCase("comment inside a flow collection", "a: [x, # c\n  y]", m(("a", .seq([.plain("x"), .plain("y")])))),
        ReaderCase("comment after a flow collection", "a: { b: c } # d", m(("a", m(("b", .plain("c")))))),
        ReaderCase("comment after the document start", "--- # start\na: b", m(("a", .plain("b")))),

        // Line endings and encoding
        ReaderCase("CRLF", "a: b\r\nc:\r\n  - d\r\n", m(("a", .plain("b")), ("c", .seq([.plain("d")])))),
        ReaderCase("lone CR", "a: b\rc: d", m(("a", .plain("b")), ("c", .plain("d")))),
        ReaderCase("BOM", "\u{FEFF}a: b", m(("a", .plain("b")))),
        ReaderCase("BOM and document start", "\u{FEFF}---\na: b", m(("a", .plain("b")))),
        ReaderCase("document end", "a: b\n...\n# after\n", m(("a", .plain("b")))),
        ReaderCase("tab in a comment line", "\t# comment\na: b", m(("a", .plain("b")))),
    ]

    static let unsupported: [ReaderCase] = [
        ReaderCase("tab in indentation", "a:\n\tb: c\nd: e", m(("a", .null), ("d", .plain("e"))), issues: [issue(2, .tabInIndentation)]),
        ReaderCase("space then tab", "a: b\n \tc: d", m(("a", .plain("b"))), issues: [issue(2, .tabInIndentation)]),
        ReaderCase("anchor", "a: &x b", m(("a", .plain("b"))), issues: [issue(1, .unsupported(.anchor))]),
        ReaderCase("anchor before a block", "a: &x\n  b: c", m(("a", m(("b", .plain("c"))))), issues: [issue(1, .unsupported(.anchor))]),
        ReaderCase("alias", "a: b\nc: *x", m(("a", .plain("b")), ("c", .invalid)), issues: [issue(2, .unsupported(.alias))]),
        ReaderCase("alias in flow", "a: [b, *x, c]", m(("a", .seq([.plain("b"), .invalid, .plain("c")]))), issues: [issue(1, .unsupported(.alias))]),
        ReaderCase("alias as a key", "*x: 1\nb: 2", m(("b", .plain("2"))), issues: [issue(1, .unsupported(.alias))]),
        ReaderCase("tag", "a: !!str b", m(("a", .plain("b"))), issues: [issue(1, .unsupported(.tag))]),
        ReaderCase("local tag", "a: !mine [b]", m(("a", .seq([.plain("b")]))), issues: [issue(1, .unsupported(.tag))]),
        ReaderCase(
            "literal block scalar",
            "a: |\n  line 1\n\n  line 2: x\nb: c",
            m(("a", .invalid), ("b", .plain("c"))),
            issues: [issue(1, .unsupported(.blockScalar))]
        ),
        ReaderCase(
            "folded block scalar",
            "x:\n  a: >-\n    text\n  b: c",
            m(("x", m(("a", .invalid), ("b", .plain("c"))))),
            issues: [issue(2, .unsupported(.blockScalar))]
        ),
        ReaderCase("pipe inside a plain scalar", "a: b|c", m(("a", .plain("b|c")))),
        ReaderCase(
            "second document",
            "a: b\n---\nc: d",
            m(("a", .plain("b"))),
            issues: [issue(2, .unsupported(.multipleDocuments))]
        ),
        ReaderCase(
            "content after the document end",
            "a: b\n...\nc: d\ne: f",
            m(("a", .plain("b"))),
            issues: [issue(3, .unsupported(.multipleDocuments))]
        ),
        ReaderCase("two document starts", "---\n---\na: b", nil, issues: [issue(2, .unsupported(.multipleDocuments))]),
        ReaderCase(
            "complex key",
            "? a\n: b\nc: d",
            m(("c", .plain("d"))),
            issues: [issue(1, .unsupported(.complexKey))]
        ),
        ReaderCase(
            "indented complex key",
            "x:\n  ? [a, b]\n  : c\n  d: e",
            m(("x", m(("d", .plain("e"))))),
            issues: [issue(2, .unsupported(.complexKey))]
        ),
        ReaderCase("complex key in flow", "{ ? a : b }", m(("a", .plain("b"))), issues: [issue(1, .unsupported(.complexKey))]),
        ReaderCase(
            "directive",
            "%YAML 1.2\n---\na: b",
            m(("a", .plain("b"))),
            issues: [issue(1, .unsupported(.directive))]
        ),
        ReaderCase("content on the document start line", "--- a\nb: c", m(("b", .plain("c"))), issues: [issue(1, .unexpectedContent)]),

        // Quotes
        ReaderCase(
            "unterminated single quote",
            "a: 'abc\nb: c",
            m(("a", .invalid), ("b", .plain("c"))),
            issues: [issue(1, .unterminatedQuote)]
        ),
        ReaderCase(
            "unterminated double quote",
            "a: \"abc\nb: c",
            m(("a", .invalid), ("b", .plain("c"))),
            issues: [issue(1, .unterminatedQuote)]
        ),
        ReaderCase("backslash at the line end", "a: \"abc\\\nb: c", m(("a", .invalid), ("b", .plain("c"))), issues: [issue(1, .unterminatedQuote)]),
        ReaderCase("unknown escape", #"a: "x\qy""#, m(("a", .invalid)), issues: [issue(1, .invalidEscapeSequence)]),
        ReaderCase("text after a closing quote", "a: \"b\"c\nd: e", m(("a", .invalid), ("d", .plain("e"))), issues: [issue(1, .unexpectedContent)]),
        ReaderCase("second scalar after a quote", "a: 'b' c", m(("a", .single("b"))), issues: [issue(1, .unexpectedContent)]),
        ReaderCase("hash right after a closing quote", "a: 'b'#c\nd: e", m(("a", .invalid), ("d", .plain("e"))), issues: [issue(1, .unexpectedContent)]),

        // Flow collections
        ReaderCase(
            "unterminated flow sequence swallows the rest",
            "a: [b, c\nd: e",
            m(("a", .invalid)),
            issues: [issue(1, .unterminatedFlowCollection)]
        ),
        ReaderCase(
            "mismatched closer, then unterminated",
            "a: { b: [c }\nd: e",
            m(("a", .invalid)),
            issues: [issue(1, .unexpectedContent), issue(1, .unterminatedFlowCollection)]
        ),
        ReaderCase("unterminated at the end", "a: { b: c", m(("a", .invalid)), issues: [issue(1, .unterminatedFlowCollection)]),
        ReaderCase(
            "nested unterminated reported once",
            "a: { b: [c, { d: e",
            m(("a", .invalid)),
            issues: [issue(1, .unterminatedFlowCollection)]
        ),
        ReaderCase("stray closing bracket", "a: ]\nb: c", m(("a", .invalid), ("b", .plain("c"))), issues: [issue(1, .unexpectedContent)]),
        ReaderCase("mismatched bracket", "a: [b}\nc: d", m(("a", .invalid), ("c", .plain("d"))), issues: [issue(1, .unexpectedContent)]),
        ReaderCase("empty flow item", "a: [b, , c]", m(("a", .invalid)), issues: [issue(1, .unexpectedContent)]),
        ReaderCase("mapping pair in a flow sequence", "a: [b: c]", m(("a", .invalid)), issues: [issue(1, .unexpectedContent)]),
        ReaderCase("text after a flow collection", "a: [b] c\nd: e", m(("a", .seq([.plain("b")])), ("d", .plain("e"))), issues: [issue(1, .unexpectedContent)]),
        ReaderCase("hash right after a flow collection", "a: [b]#c", m(("a", .seq([.plain("b")]))), issues: [issue(1, .unexpectedContent)]),
        ReaderCase("key without a value in flow", "a: { b, c: d }", m(("a", m(("c", .plain("d"))))), issues: [issue(1, .missingColon)]),
        ReaderCase("dash in flow", "a: [- b]", m(("a", .invalid)), issues: [issue(1, .unexpectedContent)]),

        // Structure
        ReaderCase("missing colon", "a: b\nc\nd: e", m(("a", .plain("b")), ("d", .plain("e"))), issues: [issue(2, .missingColon)]),
        ReaderCase("first line without a colon", "a\nb: c", m(("b", .plain("c"))), issues: [issue(1, .missingColon)]),
        ReaderCase(
            "over-indented line and its children",
            "a: b\n  c: d\n    e: f\ng: h",
            m(("a", .plain("b")), ("g", .plain("h"))),
            issues: [issue(2, .invalidIndentation)]
        ),
        ReaderCase(
            "dedent to an unused column",
            "a:\n    b: c\n  d: e\nf: g",
            m(("a", m(("b", .plain("c")))), ("f", .plain("g"))),
            issues: [issue(3, .invalidIndentation)]
        ),
        ReaderCase("dedent below an indented root", "  a: b\nc: d", m(("a", .plain("b"))), issues: [issue(2, .invalidIndentation)]),
        ReaderCase("item among keys", "a: b\n- c\nd: e", m(("a", .plain("b")), ("d", .plain("e"))), issues: [issue(2, .mixedCollection)]),
        ReaderCase("key among items", "- a\nb: c\n- d", .seq([.plain("a"), .plain("d")]), issues: [issue(2, .mixedCollection)]),
        ReaderCase(
            "key under an indented sequence",
            "a:\n  - x\n  y: z\nb: c",
            m(("a", .seq([.plain("x")])), ("b", .plain("c"))),
            issues: [issue(3, .mixedCollection)]
        ),
        ReaderCase("two pairs on one line", "a: b: c\nd: e", m(("a", .invalid), ("d", .plain("e"))), issues: [issue(1, .unexpectedContent)]),
        ReaderCase("item on a key's line", "a: - b\nc: d", m(("a", .invalid), ("c", .plain("d"))), issues: [issue(1, .unexpectedContent)]),
        ReaderCase("flow key", "[a]: b\nc: d", m(("c", .plain("d"))), issues: [issue(1, .nonScalarKey)]),
        ReaderCase("flow mapping key", "a: 1\n{ b: c }: d\ne: f", m(("a", .plain("1")), ("e", .plain("f"))), issues: [issue(2, .nonScalarKey)]),
        ReaderCase("flow key in flow", "{ [a]: b }", .invalid, issues: [issue(1, .nonScalarKey)]),
        ReaderCase("empty key", ": b\nc: d", m(("c", .plain("d"))), issues: [issue(1, .nonScalarKey)]),
        ReaderCase("reserved character", "a: @b\nc: d", m(("a", .invalid), ("c", .plain("d"))), issues: [issue(1, .unexpectedContent)]),
        ReaderCase("comma starting a block value", "a: ,b", m(("a", .invalid)), issues: [issue(1, .unexpectedContent)]),
        ReaderCase(
            "duplicate key keeps the first",
            "a: 1\nb: 2\na: 3",
            m(("a", .plain("1")), ("b", .plain("2"))),
            issues: [issue(3, .duplicateKey(previousLine: 1), "a")]
        ),
        ReaderCase(
            "duplicate key with a quoted spelling",
            "a: 1\n'a': 2",
            m(("a", .plain("1"))),
            issues: [issue(2, .duplicateKey(previousLine: 1), "a")]
        ),
        ReaderCase(
            "duplicate key in flow",
            "{ a: 1,\n  a: 2 }",
            m(("a", .plain("1"))),
            issues: [issue(2, .duplicateKey(previousLine: 1), "a")]
        ),
        ReaderCase(
            "duplicate key with a block value is skipped whole",
            "a:\n  b: 1\na:\n  c: 2\nd: 3",
            m(("a", m(("b", .plain("1")))), ("d", .plain("3"))),
            issues: [issue(3, .duplicateKey(previousLine: 1), "a")]
        ),
        ReaderCase(
            "issues in line order",
            "a: &x b\nc: *y\nd:\n\te: f",
            m(("a", .plain("b")), ("c", .invalid), ("d", .null)),
            issues: [issue(1, .unsupported(.anchor)), issue(2, .unsupported(.alias)), issue(4, .tabInIndentation)]
        ),
    ]

    @Test("supported constructs", arguments: supported)
    func supportedConstructs(_ testCase: ReaderCase) {
        let result = ManifestReader.read(testCase.input)
        #expect(result.root?.yaml == testCase.tree)
        #expect(result.issues == testCase.issues)
    }

    @Test("unsupported constructs and errors", arguments: unsupported)
    func unsupportedConstructs(_ testCase: ReaderCase) {
        let result = ManifestReader.read(testCase.input)
        #expect(result.root?.yaml == testCase.tree)
        #expect(sorted(result.issues) == testCase.issues)
    }

    @Test func everyConstructHasACase() {
        let covered = Set(Self.unsupported.flatMap(\.issues).compactMap { issue -> ManifestIssue.Construct? in
            if case .unsupported(let construct) = issue.kind { return construct }
            return nil
        })
        #expect(covered == Set(ManifestIssue.Construct.allCases))
    }

    @Test func tablesAreLarge() {
        #expect(Self.supported.count >= 60)
        #expect(Self.unsupported.count >= 50)
    }

    // MARK: - Lines

    @Test func nodesCarryTheirLines() throws {
        let text = "\n# c\na: b\nc:\n  - d\n  - { e: f,\n      g: h }\n"
        let root = try #require(ManifestReader.read(text).root)
        guard case .mapping(let entries) = root.value else {
            Issue.record("expected a mapping")
            return
        }
        #expect(entries.map(\.keyLine) == [3, 4])
        #expect(entries[0].value.line == 3)
        guard case .sequence(let items) = entries[1].value.value else {
            Issue.record("expected a sequence")
            return
        }
        #expect(items.map(\.line) == [5, 6])
        guard case .mapping(let flow) = items[1].value else {
            Issue.record("expected a flow mapping")
            return
        }
        #expect(flow.map(\.keyLine) == [6, 7])
    }

    @Test func crlfAndCRCountLinesLikeLF() {
        for separator in ["\n", "\r\n", "\r"] {
            let text = ["a: b", "c: &x d", "e: f"].joined(separator: separator)
            #expect(ManifestReader.read(text).issues == [issue(2, .unsupported(.anchor))])
        }
    }

    @Test func tokenColumnsAndLineStarts() {
        var tokenizer = ManifestTokenizer(text: "a: [b,\n  c]\n- d")
        tokenizer.run()
        let summary = tokenizer.tokens.map { "\($0.line):\($0.column)\($0.startsLine ? "^" : "")" }
        #expect(summary == ["1:0^", "1:1", "1:3", "1:4", "1:5", "2:2^", "2:3", "3:0^", "3:2"])
    }

    // MARK: - Nesting

    @Test func flowNestingUpToTheLimitIsRead() {
        // The root mapping is level 1, so the limit leaves room for limit - 1 sequences.
        let levels = EnvToolsLimits.maxManifestNestingDepth - 1
        let text = "a: " + String(repeating: "[", count: levels) + "x" + String(repeating: "]", count: levels)
        let result = ManifestReader.read(text)
        #expect(result.issues.isEmpty)
        var expected = YAMLValue.plain("x")
        for _ in 0..<levels { expected = .seq([expected]) }
        #expect(result.root?.yaml == m(("a", expected)))
    }

    @Test func flowNestingPastTheLimitIsReported() {
        let levels = EnvToolsLimits.maxManifestNestingDepth
        let text = "a: " + String(repeating: "[", count: levels) + "x" + String(repeating: "]", count: levels) + "\nb: c"
        let result = ManifestReader.read(text)
        #expect(result.issues == [issue(1, .nestingTooDeep(limit: EnvToolsLimits.maxManifestNestingDepth))])
        guard case .mapping(let entries) = result.root?.value else {
            Issue.record("expected a mapping")
            return
        }
        #expect(entries.map(\.key) == ["a", "b"])
    }

    @Test func blockNestingPastTheLimitIsReported() {
        let depth = EnvToolsLimits.maxManifestNestingDepth + 1
        let lines = (0..<depth).map { String(repeating: " ", count: $0 * 2) + "k\($0):" }
        let text = (lines + ["after: x"]).joined(separator: "\n")
        let result = ManifestReader.read(text)
        #expect(result.issues == [issue(depth, .nestingTooDeep(limit: EnvToolsLimits.maxManifestNestingDepth))])
        guard case .mapping(let entries) = result.root?.value else {
            Issue.record("expected a mapping")
            return
        }
        #expect(entries.map(\.key) == ["k0", "after"])
    }

    @Test func deepCompactSequencesStop() {
        let text = String(repeating: "- ", count: 1_000) + "x"
        let result = ManifestReader.read(text)
        #expect(result.issues == [issue(1, .nestingTooDeep(limit: EnvToolsLimits.maxManifestNestingDepth))])
    }

    @Test func thousandsOfOpenBracketsStop() {
        let text = "a: " + String(repeating: "[", count: 20_000)
        let result = ManifestReader.read(text)
        #expect(result.issues == [
            issue(1, .nestingTooDeep(limit: EnvToolsLimits.maxManifestNestingDepth)),
            issue(1, .unterminatedFlowCollection),
        ])
    }

    // MARK: - Names in issues

    @Test func duplicateKeysAreSanitized() {
        let result = ManifestReader.read("\"a\u{202E}b\": 1\n\"a\u{202E}b\": 2")
        #expect(result.issues == [issue(2, .duplicateKey(previousLine: 1), "ab")])
    }

    private func sorted(_ issues: [ManifestIssue]) -> [ManifestIssue] {
        issues.enumerated().sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }.map(\.element)
    }
}
