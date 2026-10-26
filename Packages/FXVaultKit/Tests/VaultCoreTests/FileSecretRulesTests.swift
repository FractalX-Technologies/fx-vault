import Foundation
import Testing
@testable import VaultCore

/// File secrets (1.0 F1): a file's facts, Exact text or Base64, the stored size and the name a
/// file suggests. Contents are synthetic.
@Suite("File secret rules")
struct FileSecretRulesTests {
    /// A PEM-shaped text with 6 lines and one trailing line break (257 bytes, as the board's file).
    static let pemText = "-----BEGIN EXAMPLE FIXTURE-----\n"
        + String(repeating: "A", count: 64) + "\n"
        + String(repeating: "B", count: 64) + "\n"
        + String(repeating: "C", count: 61) + "\n"
        + "DD\n"
        + "-----END EXAMPLE FIXTURE-----\n"

    @Test func aTextFileCountsItsLinesWithoutTheTrailingBreak() {
        let bytes = SecretBytes(utf8: Self.pemText)
        defer { bytes.wipe() }
        let facts = FileSecretRules.facts(of: bytes)
        #expect(facts.byteCount == 257)
        #expect(facts.base64ByteCount == 344)
        #expect(facts.isText)
        #expect(facts.lineCount == 6)
        #expect(facts.trailingLineBreakCount == 1)
        #expect(FileSecretRules.storedByteCount(of: facts, as: .text) == 256)
        #expect(FileSecretRules.storedByteCount(of: facts, as: .base64) == 344)
    }

    @Test func crlfAndEmptyFiles() {
        let windows = SecretBytes(utf8: "a\r\nb\r\n\r\n")
        defer { windows.wipe() }
        let facts = FileSecretRules.facts(of: windows)
        #expect(facts.lineCount == 2)
        #expect(facts.trailingLineBreakCount == 4)

        let empty = SecretBytes(utf8: "")
        defer { empty.wipe() }
        #expect(FileSecretRules.facts(of: empty).lineCount == 0)
        #expect(FileSecretRules.facts(of: empty).base64ByteCount == 0)
    }

    /// Invalid UTF-8 or a NUL byte is binary: no lines, and Base64 whatever was chosen.
    @Test func aBinaryFileIsAlwaysStoredAsBase64() {
        for raw in [[0xFF, 0xFE, 0x41], [0x41, 0x00, 0x42]] as [[UInt8]] {
            let bytes = SecretBytes(copying: raw)
            defer { bytes.wipe() }
            let facts = FileSecretRules.facts(of: bytes)
            #expect(!facts.isText)
            #expect(facts.lineCount == nil)
            #expect(FileSecretRules.encoding(.text, for: facts) == .base64)
            #expect(FileSecretRules.storedByteCount(of: facts, as: .text) == 4)
            #expect(FileSecretRules.model(fileName: "cert.der", facts: facts, encoding: .text).encoding == .base64)
        }
    }

    /// The encoder writes into its own buffer; it must agree with Foundation for every padding.
    @Test(arguments: [0, 1, 2, 3, 4, 5, 6, 47, 257])
    func base64MatchesFoundation(_ length: Int) {
        let raw = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
        let bytes = SecretBytes(copying: raw)
        let encoded = FileSecretRules.value(of: bytes, as: .base64)
        defer {
            bytes.wipe()
            encoded.wipe()
        }
        #expect(encoded.utf8String() == Data(raw).base64EncodedString())
        #expect(encoded.count == FileSecretRules.base64Count(length))
    }

    @Test func exactTextIsTheFileAsIs() {
        let bytes = SecretBytes(utf8: Self.pemText)
        let value = FileSecretRules.value(of: bytes, as: .text)
        defer {
            bytes.wipe()
            value.wipe()
        }
        #expect(value == bytes)
    }

    @Test func theModelKeepsTheFileNameOnly() {
        let bytes = SecretBytes(utf8: Self.pemText)
        defer { bytes.wipe() }
        let facts = FileSecretRules.facts(of: bytes)
        let model = FileSecretRules.model(fileName: "/Users/user-a/Keys/AuthKey_ABC123.p8", facts: facts, encoding: .text)
        #expect(model == FileSecretModel(fileName: "AuthKey_ABC123.p8", lineCount: 6, encoding: .text))
        // Cut by Unicode scalars, as SQLite's length() counts them: "é" written as e + U+0301.
        let long = FileSecretRules.model(fileName: String(repeating: "e\u{301}", count: 200), facts: facts, encoding: .text)
        #expect(long.fileName.unicodeScalars.count == Limits.maxFileSecretNameLength)
    }

    @Test(arguments: [
        ("AuthKey_ABC123.p8", "AUTH_KEY_P8"),
        ("APNSKey.p8", "APNS_KEY_P8"),
        ("service-account.json", "SERVICE_ACCOUNT_JSON"),
        ("firebase-adminsdk-fbsvc-1a2b3c4d.json", "FIREBASE_ADMINSDK_FBSVC_JSON"),
        ("key2.pem", "KEY2_PEM"),
        ("github.pem", "GH_PEM"),
        ("2024-cert.pem", "_2024_CERT_PEM"),
        ("Producción.pem", "PRODUCCION_PEM"),
    ])
    func theFileNameSuggestsASecretName(_ fileName: String, _ expected: String) {
        #expect(FileSecretRules.suggestedName(forFileName: fileName) == expected)
    }

    @Test func nothingUsableSuggestsNothing() {
        #expect(FileSecretRules.suggestedName(forFileName: "") == nil)
        #expect(FileSecretRules.suggestedName(forFileName: "---") == nil)
    }

    @Test func onlyKeyFilesCanBeDropped() {
        #expect(FileSecretRules.isDroppable(fileName: "AuthKey.P8"))
        #expect(FileSecretRules.isDroppable(fileName: "server.pem"))
        #expect(FileSecretRules.isDroppable(fileName: "service-account.json"))
        #expect(!FileSecretRules.isDroppable(fileName: "notes.txt"))
        #expect(!FileSecretRules.isDroppable(fileName: "p8"))
    }
}
