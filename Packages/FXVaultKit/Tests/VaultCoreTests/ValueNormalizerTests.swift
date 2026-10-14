import Foundation
import Testing
import VaultCore

@Suite("ValueNormalizer (D32)")
struct ValueNormalizerTests {
    @Test(arguments: [
        ("value", "value", false),
        ("value\n", "value", true),
        ("value\r\n", "value", true),
        ("value\n\n\r\n\r", "value", true),
        ("value\r", "value", true),
        ("line1\nline2\n", "line1\nline2", true),
        ("line1\r\nline2", "line1\r\nline2", false),
        ("  spaced  ", "  spaced  ", false),
        ("\nleading", "\nleading", false),
        ("tab\t", "tab\t", false),
        ("\"--'\t", "\"--'\t", false),
        ("ünïcödé\n", "ünïcödé", true),
        ("-----BEGIN KEY-----\nabc\n-----END KEY-----\n", "-----BEGIN KEY-----\nabc\n-----END KEY-----", true),
    ])
    func stripsOnlyTrailingNewlines(input: String, expected: String, stripped: Bool) throws {
        let fromString = try ValueNormalizer.normalize(input)
        #expect(fromString.value == expected)
        #expect(fromString.didStripTrailingNewlines == stripped)

        let secret = SecretBytes(utf8: input)
        let fromBytes = try ValueNormalizer.normalize(secret)
        #expect(fromBytes.value.utf8String() == expected)
        #expect(fromBytes.didStripTrailingNewlines == stripped)
        #expect(fromBytes.value !== secret)
        #expect(secret.utf8String() == input)
    }

    @Test(arguments: ["", "\n", "\r\n", "\n\r\n\r"])
    func rejectsEmptyAfterStripping(input: String) {
        #expect(throws: ValidationError.emptyValue) {
            try ValueNormalizer.normalize(input)
        }
        #expect(throws: ValidationError.emptyValue) {
            try ValueNormalizer.normalize(SecretBytes(utf8: input))
        }
    }

    @Test func acceptsExactlyTheMaximumSize() throws {
        let max = String(repeating: "a", count: Limits.maxValueBytes)
        #expect(try ValueNormalizer.normalize(max).value.utf8.count == Limits.maxValueBytes)
        // Trailing newlines do not count against the limit.
        let withNewline = max + "\r\n"
        let normalized = try ValueNormalizer.normalize(SecretBytes(utf8: withNewline))
        #expect(normalized.value.count == Limits.maxValueBytes)
        #expect(normalized.didStripTrailingNewlines)
    }

    @Test func rejectsOneByteOverTheMaximum() {
        let tooLarge = String(repeating: "a", count: Limits.maxValueBytes + 1)
        #expect(throws: ValidationError.valueTooLarge(limit: Limits.maxValueBytes)) {
            try ValueNormalizer.normalize(tooLarge)
        }
        #expect(throws: ValidationError.valueTooLarge(limit: Limits.maxValueBytes)) {
            try ValueNormalizer.normalize(SecretBytes(utf8: tooLarge))
        }
    }

    @Test func sizeIsMeasuredInUTF8Bytes() {
        // 24,001 two-byte characters = 48,002 bytes.
        let multiByte = String(repeating: "é", count: Limits.maxValueBytes / 2 + 1)
        #expect(throws: ValidationError.valueTooLarge(limit: Limits.maxValueBytes)) {
            try ValueNormalizer.normalize(multiByte)
        }
    }

    @Test func binaryValuesAreNormalizedBytewise() throws {
        let bytes: [UInt8] = [0xFF, 0x00, 0x0D, 0x0A, 0x0A]
        let normalized = try ValueNormalizer.normalize(SecretBytes(copying: bytes))
        #expect(normalized.value.withUnsafeBytes { Array($0) } == [0xFF, 0x00])
        #expect(normalized.didStripTrailingNewlines)
    }

    @Test func trailingNewlineCount() {
        let bytes = Array("abc\r\n\n".utf8)
        #expect(bytes.withUnsafeBytes { ValueNormalizer.trailingNewlineCount(in: $0) } == 3)
        #expect([UInt8]().withUnsafeBytes { ValueNormalizer.trailingNewlineCount(in: $0) } == 0)
    }
}
