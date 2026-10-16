import Foundation
import Testing
@testable import DestinationKit
import VaultCore

/// The JSON body writer (RFC 8259 escaping straight into `SecretBytes`).
@Suite("JSON body writer")
struct JSONBodyWriterTests {
    private func encode(_ value: JSONBodyValue) throws -> String {
        try JSONBodyWriter.encode(value).testText
    }

    @Test func objectsKeepMemberOrderAndAreCompact() throws {
        let body = JSONBodyValue.members([
            "key": .string("NAME"),
            "value": .secret(TestValues.secret("v")),
            "type": .string("encrypted"),
            "target": .strings(["production", "preview"]),
            "upsert": .bool(true),
            "count": .integer(-42),
            "comment": .null,
            "nested": .members(["a": .array([.integer(1), .bool(false)])]),
        ])
        #expect(try encode(body) == #"{"key":"NAME","value":"v","type":"encrypted","target":["production","preview"],"upsert":true,"count":-42,"comment":null,"nested":{"a":[1,false]}}"#)
    }

    @Test func emptyContainers() throws {
        #expect(try encode(.array([])) == "[]")
        #expect(try encode(.object([])) == "{}")
        #expect(try encode(.secret(SecretBytes(count: 0))) == #""""#)
    }

    @Test(arguments: [
        ("\"", #""\"""#),
        ("\\", #""\\""#),
        ("/", #""/""#),
        ("\u{08}\u{0C}\n\r\t", #""\b\f\n\r\t""#),
        ("\u{00}\u{01}\u{1F}", #""\u0000\u0001\u001f""#),
        ("\u{7F}", "\"\u{7F}\""),
        ("é", "\"é\""),
        ("🚀", "\"🚀\""),
        ("\u{2028}", "\"\u{2028}\""),
    ])
    func escapesPerRFC8259(input: String, expected: String) throws {
        #expect(try encode(.secret(TestValues.secret(input))) == expected)
        #expect(try encode(.string(input)) == expected, "value-free strings use the same escaping")
    }

    @Test func escapedOutputRoundTripsThroughFoundation() throws {
        var allControls = (0..<0x20).map { String(UnicodeScalar(UInt8($0))) }.joined()
        allControls += TestValues.trickyValue
        let data = try JSONBodyWriter.encode(.members(["value": .secret(TestValues.secret(allControls))]))
            .withUnsafeBytes { Data($0) }
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(decoded["value"] == allControls)
    }

    @Test func invalidUTF8SecretIsRefused() {
        for bytes: [UInt8] in [[0xFF], [0xC0, 0x80], [0xED, 0xA0, 0x80], [0xE2, 0x82], [0xF4, 0x90, 0x80, 0x80]] {
            #expect(throws: DestinationError.valueNotUTF8) {
                try JSONBodyWriter.encode(.secret(SecretBytes(copying: bytes)))
            }
        }
    }

    @Test func duplicateKeysAndDeepNestingAreProgrammingErrors() {
        #expect(throws: DestinationError.invalidRequest(code: nil)) {
            try JSONBodyWriter.encode(.object([JSONBodyMember("a", .null), JSONBodyMember("a", .null)]))
        }
        var deep = JSONBodyValue.null
        for _ in 0...JSONBodyWriter.maxDepth {
            deep = .array([deep])
        }
        #expect(throws: DestinationError.invalidRequest(code: nil)) {
            try JSONBodyWriter.encode(deep)
        }
    }

    @Test func utf8ValidatorFollowsTable3_7() {
        let valid: [[UInt8]] = [[0x41], [0xC2, 0x80], [0xE0, 0xA0, 0x80], [0xED, 0x9F, 0xBF], [0xF0, 0x90, 0x80, 0x80], [0xF4, 0x8F, 0xBF, 0xBF]]
        let invalid: [[UInt8]] = [[0x80], [0xC1, 0xBF], [0xE0, 0x9F, 0xBF], [0xED, 0xA0, 0x80], [0xF0, 0x8F, 0xBF, 0xBF], [0xF5, 0x80, 0x80, 0x80], [0xF0, 0x90, 0x80]]
        for bytes in valid {
            #expect(bytes.withUnsafeBytes { UTF8Validation.isValid($0) }, "\(bytes)")
        }
        for bytes in invalid {
            #expect(!bytes.withUnsafeBytes { UTF8Validation.isValid($0) }, "\(bytes)")
        }
    }
}

/// The secret JSON scanner.
@Suite("Secret JSON scanner")
struct SecretJSONScannerTests {
    private func document(_ text: String) throws -> SecretJSONDocument {
        try SecretJSONDocument(parsing: TestValues.secret(text))
    }

    @Test func extractsTopLevelValueWithEscapes() throws {
        let body = try Fixture.data("keyvault/secret-get.json")
        let value = try #require(try SecretJSONDocument.secretField("value", in: SecretBytes(body)))
        #expect(value.testText == "fixture \"quoted\" value\nété 🚀 /end")
    }

    @Test(arguments: [
        (#"{"value":"\u0041\u00e9\u20ac"}"#, "Aé€"),
        (#"{"value":"\ud83d\ude80"}"#, "🚀"),
        (#"{"value":"\uD834\uDD1E x"}"#, "𝄞 x"),
        (#"{"value":"\"\\\/\b\f\n\r\t"}"#, "\"\\/\u{08}\u{0C}\n\r\t"),
        (#"{"value":""}"#, ""),
        (#"{"value":"plain"}"#, "plain"),
    ])
    func unescapes(json: String, expected: String) throws {
        let value = try #require(try SecretJSONDocument.secretField("value", in: TestValues.secret(json)))
        #expect(value.testText == expected)
    }

    @Test func nestedObjectsBeforeValueAreSkipped() throws {
        let json = #"{"attributes":{"value":"inner","list":[{"value":"deep"}]},"tags":{"value":"tag"},"value":"outer"}"#
        let document = try document(json)
        #expect(document.secret("value")?.testText == "outer", "only the top-level field")
        #expect(document.secret("attributes", "value")?.testText == "inner")
        #expect(document.secret("attributes", "list", 0, "value")?.testText == "deep")
    }

    @Test func missingOrNonStringFieldIsNil() throws {
        #expect(try SecretJSONDocument.secretField("value", in: TestValues.secret(#"{"id":"x"}"#)) == nil)
        #expect(try SecretJSONDocument.secretField("value", in: TestValues.secret(#"{"value":42}"#)) == nil)
        #expect(try SecretJSONDocument.secretField("value", in: TestValues.secret(#"{"value":null}"#)) == nil)
        #expect(try SecretJSONDocument.secretField("value", in: TestValues.secret(#"["value"]"#)) == nil)
    }

    @Test func readsValueFreeFields() throws {
        let document = try document(#"{"a":{"n":1790000000123,"neg":-5,"f":1.5,"e":1.7e3,"big":99999999999999999999,"t":true,"s":"x","arr":["p","q"],"mixed":["p",1],"nil":null}}"#)
        #expect(document.integer("a", "n") == 1_790_000_000_123)
        #expect(document.integer("a", "neg") == -5)
        #expect(document.integer("a", "f") == nil, "not integral")
        #expect(document.integer("a", "e") == 1700)
        #expect(document.integer("a", "big") == nil, "does not fit Int64")
        #expect(document.bool("a", "t") == true)
        #expect(document.string("a", "s") == "x")
        #expect(document.strings("a", "arr") == ["p", "q"])
        #expect(document.strings("a", "mixed") == nil)
        #expect(document.isNull("a", "nil"))
        #expect(document.contains("a", "nil"))
        #expect(!document.contains("a", "missing"))
        #expect(document.keys("a")?.contains("arr") == true)
        #expect(document.child("a", "arr")?.kind == .array)
        #expect(document.elements("a", "arr")?.count == 2)
        #expect(document.string("a", "arr", 5) == nil, "index out of range")
        #expect(document.string("a", 0) == nil, "index into an object")
    }

    @Test func acceptsWhitespaceAndByteOrderMark() throws {
        let text = "\u{FEFF} \n\t{ \"value\" : \"v\" , \"n\" : [ 1 , 2 ] }\r\n"
        let document = try document(text)
        #expect(document.secret("value")?.testText == "v")
    }

    @Test(arguments: [
        "",
        " ",
        "{",
        "}",
        "{\"value\":}",
        "{\"value\":\"unterminated}",
        "{\"value\":\"a\" \"b\":1}",
        "{\"value\":\"a\",}",
        "[1,]",
        "[1 2]",
        "{value:\"a\"}",
        "{\"a\":1}{",
        "{\"a\":1} x",
        "{\"a\":01}",
        "{\"a\":-}",
        "{\"a\":1.}",
        "{\"a\":1e}",
        "{\"a\":+1}",
        "{\"a\":tru}",
        "{\"a\":nul}",
        "{\"a\":\"\\x\"}",
        "{\"a\":\"\\u12\"}",
        "{\"a\":\"\\u12G4\"}",
        "{\"a\":\"\\ud83d\"}",
        "{\"a\":\"\\ud83d\\u0041\"}",
        "{\"a\":\"\\ude80\"}",
        "{\"a\":\"line\nbreak\"}",
        "{\"a\":\"tab\there\"}",
        "{\"a\":1,\"a\":2}",
        "'single'",
        "NaN",
    ])
    func malformedInputThrowsWithoutTrapping(text: String) {
        #expect(throws: DestinationError.decoding) {
            try SecretJSONDocument(parsing: TestValues.secret(text))
        }
    }

    @Test func invalidUTF8InsideStringsIsRejected() {
        for bytes: [UInt8] in [[0x22, 0xFF, 0x22], [0x22, 0xC3, 0x22], [0x22, 0xED, 0xA0, 0x80, 0x22]] {
            #expect(throws: DestinationError.decoding) {
                try SecretJSONDocument(parsing: SecretBytes(copying: bytes))
            }
        }
    }

    @Test func nestingIsBounded() throws {
        let ok = String(repeating: "[", count: SecretJSONDocument.maxDepth) + String(repeating: "]", count: SecretJSONDocument.maxDepth)
        _ = try document(ok)
        let deep = String(repeating: "[", count: SecretJSONDocument.maxDepth + 1) + String(repeating: "]", count: SecretJSONDocument.maxDepth + 1)
        #expect(throws: DestinationError.decoding) {
            try SecretJSONDocument(parsing: TestValues.secret(deep))
        }
        let hostile = String(repeating: "[", count: 100_000)
        #expect(throws: DestinationError.decoding) {
            try SecretJSONDocument(parsing: TestValues.secret(hostile))
        }
    }

    @Test func randomBytesNeverTrap() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array(#"{}[]",:\"\u0041truefalsenull-0123456789.eE \n"#.utf8) + [0xFF, 0xC3, 0xED]
        for _ in 0..<2000 {
            let length = Int.random(in: 0..<40, using: &generator)
            let bytes = (0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] }
            if let document = try? SecretJSONDocument(parsing: SecretBytes(copying: bytes)) {
                _ = document.secret("value")
                _ = document.string(0)
                _ = document.integer("a")
            }
        }
    }

    @Test func writerOutputParsesBack() throws {
        let body = try JSONBodyWriter.encode(.members(["value": .secret(TestValues.secret(TestValues.trickyValue)), "n": .integer(7)]))
        let document = try SecretJSONDocument(parsing: body)
        #expect(document.secret("value")?.testText == TestValues.trickyValue)
        #expect(document.integer("n") == 7)
    }
}
