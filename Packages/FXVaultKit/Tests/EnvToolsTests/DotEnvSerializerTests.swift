import Foundation
import Testing
import VaultCore
@testable import EnvTools

private func entry(_ key: String, _ value: String) -> DotEnvEntryModel {
    DotEnvEntryModel(key: key, value: SecretBytes(utf8: value))
}

@Suite("DotEnvSerializer")
struct DotEnvSerializerTests {
    @Test(
        "quoting choice",
        arguments: [
            ("", DotEnvQuoting.none),
            ("abc", .none),
            ("https://api.example.test:8443/v1/a=b,c%20d", .none),
            ("https://api.example.test/v1?a=b", .single),
            ("user@host.test", .none),
            ("a b", .single),
            ("$HOME", .single),
            ("${X}", .single),
            ("#tag", .single),
            ("l1\nl2", .single),
            ("é", .single),
            (#"back\slash"#, .single),
            ("it's", .double),
            ("a\rb", .double),
            ("it's\nmulti", .double),
        ]
    )
    func quotingChoice(value: String, expected: DotEnvQuoting) {
        #expect(DotEnvSerializer.quoting(for: SecretBytes(utf8: value)) == expected)
    }

    @Test func exactOutput() throws {
        let output = try DotEnvSerializer.serialize(
            [
                entry("A", "1"),
                entry("B", "a b"),
                entry("C", "it's \"q\"\n${X}\\"),
                entry("D", ""),
                entry("E", "line1\nline2"),
            ],
            headerComments: ["Exported by FX Vault", "owner/repo (production)"]
        )
        let expected = """
        # Exported by FX Vault
        # owner/repo (production)
        A=1
        B='a b'
        C="it's \\"q\\"\\n\\${X}\\\\"
        D=
        E='line1
        line2'

        """
        #expect(output.utf8String() == expected)
    }

    @Test func emptyInputGivesEmptyFile() throws {
        let output = try DotEnvSerializer.serialize([])
        #expect(output.count == 0)
    }

    @Test(
        "rejects keys that are not portable",
        arguments: ["", "1A", "A-B", "A.B", "A B", "É", "A=B"]
    )
    func rejectsInvalidKeys(key: String) {
        #expect(throws: DotEnvSerializeError.invalidKey(key)) {
            try DotEnvSerializer.serialize([entry(key, "x")])
        }
    }

    @Test func acceptsPortableKeys() {
        #expect(DotEnvSerializer.isPortableKey("_A1"))
        #expect(DotEnvSerializer.isPortableKey("lower_case"))
        #expect(DotEnvSerializer.isPortableKey("GITHUB_TOKEN"))
    }

    @Test func rejectsDuplicateKeys() {
        #expect(throws: DotEnvSerializeError.duplicateKey("A")) {
            try DotEnvSerializer.serialize([entry("A", "1"), entry("A", "2")])
        }
    }

    @Test func rejectsCommentsWithLineBreaks() {
        #expect(throws: DotEnvSerializeError.invalidComment) {
            try DotEnvSerializer.serialize([entry("A", "1")], headerComments: ["one\ntwo"])
        }
    }

    @Test func rejectsInvalidUTF8Values() {
        let value = SecretBytes(copying: [0xFF, 0x00])
        #expect(throws: DotEnvSerializeError.invalidValueEncoding(key: "A")) {
            try DotEnvSerializer.serialize([DotEnvEntryModel(key: "A", value: value)])
        }
    }

    @Test func serializingDoesNotModifyValues() throws {
        let value = SecretBytes(utf8: "it's \"x\"")
        _ = try DotEnvSerializer.serialize([DotEnvEntryModel(key: "A", value: value)])
        #expect(value.utf8String() == "it's \"x\"")
    }

    // MARK: - Round trip

    /// Fragments chosen to hit every quoting path and parser edge: quotes, both line endings,
    /// `#`, `=`, `$`/`${`, backslashes, whitespace, control characters and multi-byte UTF-8.
    private static let fragments = [
        "a", "Z", "0", "_", "-", ".", "/", ":", "@", "%", "+", ",", "~",
        " ", "\t", "\n", "\r", "\r\n", "'", "\"", "#", " #", "=", "$", "{", "}", "${", "${X}",
        "\\", "\\n", "\\\"", "export ", "é", "漢", "🙂", "\u{1}", "\u{7F}",
    ]
    private static let keyStart = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_")
    private static let keyRest = keyStart + Array("0123456789")
    private static let iterations = 1_000
    private static let maxEntries = 8
    private static let maxKeyTail = 15
    private static let maxFragments = 12

    @Test func roundTripProperty() throws {
        var generator = SeededGenerator(seed: 0x00FA_C7E5)
        var quotingSeen = Set<DotEnvQuoting>()
        for _ in 0..<Self.iterations {
            var keys = Set<String>()
            var pairs: [ParsedPair] = []
            for _ in 0..<Int.random(in: 1...Self.maxEntries, using: &generator) {
                let key = Self.randomKey(using: &generator)
                guard keys.insert(key).inserted else { continue }
                pairs.append(ParsedPair(key, Self.randomValue(using: &generator)))
            }

            let entries = pairs.map { entry($0.key, $0.value) }
            quotingSeen.formUnion(entries.map { DotEnvSerializer.quoting(for: $0.value) })
            let output = try DotEnvSerializer.serialize(entries)
            let result = try DotEnvParser.parse(output)

            #expect(result.pairs == pairs, "round trip failed for \(pairs)")
            #expect(result.issues.isEmpty, "unexpected issues \(result.issues) for \(pairs)")
        }
        // The generator must exercise every quoting path.
        #expect(quotingSeen == Set(DotEnvQuoting.allCases))
    }

    private static func randomKey(using generator: inout SeededGenerator) -> String {
        let head = keyStart.randomElement(using: &generator) ?? "A"
        let tail = (0..<Int.random(in: 0...maxKeyTail, using: &generator)).map { _ in
            keyRest.randomElement(using: &generator) ?? "A"
        }
        return String([head] + tail)
    }

    private static func randomValue(using generator: inout SeededGenerator) -> String {
        (0..<Int.random(in: 0...maxFragments, using: &generator))
            .map { _ in fragments.randomElement(using: &generator) ?? "" }
            .joined()
    }
}
