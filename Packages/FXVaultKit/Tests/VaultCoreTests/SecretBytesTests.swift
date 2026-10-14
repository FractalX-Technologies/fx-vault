import Foundation
import Testing
import VaultCore

@Suite("SecretBytes (§5.12)")
struct SecretBytesTests {
    static let plaintext = "FXV_FIXTURE_super-secret-value"

    private struct Holder: CustomStringConvertible {
        let token: SecretBytes
        var description: String { "Holder(token: \(token))" }
    }

    private struct PlainHolder {
        let token: SecretBytes
    }

    @Test func textualRepresentationsAreRedacted() {
        let secret = SecretBytes(utf8: Self.plaintext)
        let renderings = [
            secret.description,
            secret.debugDescription,
            String(describing: secret),
            String(reflecting: secret),
            "\(secret)",
            String(describing: Holder(token: secret)),
            String(describing: PlainHolder(token: secret)),
            String(reflecting: PlainHolder(token: secret)),
            String(describing: [secret]),
            String(describing: Optional(secret)),
        ]
        for rendering in renderings {
            #expect(!rendering.contains(Self.plaintext))
            #expect(!rendering.contains("super-secret"))
        }
        #expect(secret.description == SecretBytes.redacted)
        #expect(secret.debugDescription == SecretBytes.redacted)
    }

    @Test func dumpAndMirrorExposeNothing() {
        let secret = SecretBytes(utf8: Self.plaintext)
        var dumped = ""
        dump(secret, to: &dumped)
        dump(PlainHolder(token: secret), to: &dumped)
        #expect(!dumped.contains(Self.plaintext))
        #expect(Mirror(reflecting: secret).children.isEmpty)
    }

    @Test func wipeZeroesEveryByteAndKeepsTheCount() {
        let secret = SecretBytes(utf8: Self.plaintext)
        #expect(!secret.isWiped)
        secret.wipe()
        #expect(secret.isWiped)
        #expect(secret.count == Self.plaintext.utf8.count)
        #expect(secret.withUnsafeBytes { bytes in bytes.allSatisfy { $0 == 0 } })
        secret.wipe()
        #expect(secret.isWiped)
    }

    @Test func roundTripsBytesAndStrings() throws {
        let bytes: [UInt8] = [0x00, 0x01, 0xFE, 0xFF]
        #expect(SecretBytes(copying: bytes).withUnsafeBytes { Array($0) } == bytes)
        #expect(SecretBytes(Data(bytes)).withUnsafeBytes { Array($0) } == bytes)
        #expect(SecretBytes(utf8: "héllo").utf8String() == "héllo")
        #expect(SecretBytes(copying: [0xFF, 0xFE]).utf8String() == nil)
        let empty = SecretBytes(copying: [UInt8]())
        #expect(empty.isEmpty)
        #expect(empty.utf8String() == "")
    }

    @Test func wipingSourceInitZeroesTheData() {
        var data = Data(Self.plaintext.utf8)
        let secret = SecretBytes(wipingSource: &data)
        #expect(secret.utf8String() == Self.plaintext)
        #expect(data.count == Self.plaintext.utf8.count)
        #expect(data.allSatisfy { $0 == 0 })
    }

    @Test func wipingSourceInitHandlesDataSlices() {
        let whole = Data("xxSECRETxx".utf8)
        var slice = whole[2..<8]
        let secret = SecretBytes(wipingSource: &slice)
        #expect(secret.utf8String() == "SECRET")
        #expect(slice.count == 6)
        #expect(slice.allSatisfy { $0 == 0 })
    }

    @Test func zeroFilledBufferIsWritable() {
        let buffer = SecretBytes(count: 4)
        #expect(buffer.withUnsafeBytes { bytes in bytes.allSatisfy { $0 == 0 } })
        buffer.withUnsafeMutableBytes { bytes in
            for index in bytes.indices {
                bytes[index] = UInt8(index + 1)
            }
        }
        #expect(buffer.withUnsafeBytes { Array($0) } == [1, 2, 3, 4])
        #expect(SecretBytes(count: -1).isEmpty)
    }

    @Test func copyAndPrefixAreIndependent() {
        let original = SecretBytes(utf8: "abcdef")
        let copy = original.copy()
        let prefix = original.prefix(3)
        original.wipe()
        #expect(copy.utf8String() == "abcdef")
        #expect(prefix.utf8String() == "abc")
        #expect(original.prefix(100).count == original.count)
        #expect(original.prefix(-1).isEmpty)
    }

    @Test func equalityComparesContents() {
        let lhs = SecretBytes(utf8: "same")
        #expect(lhs == SecretBytes(utf8: "same"))
        #expect(lhs == lhs)
        #expect(lhs != SecretBytes(utf8: "Same"))
        #expect(lhs != SecretBytes(utf8: "same "))
        #expect(lhs != SecretBytes(utf8: ""))
        #expect(lhs.constantTimeEquals(Data("same".utf8)))
        #expect(!lhs.constantTimeEquals([UInt8]("sama".utf8)))
    }

    @Test func staticConstantTimeEquals() {
        let lhs: [UInt8] = [1, 2, 3]
        let rhs: [UInt8] = [1, 2, 4]
        lhs.withUnsafeBytes { left in
            rhs.withUnsafeBytes { right in
                #expect(!SecretBytes.constantTimeEquals(left, right))
                #expect(SecretBytes.constantTimeEquals(left, left))
                #expect(!SecretBytes.constantTimeEquals(left, UnsafeRawBufferPointer(rebasing: left[0..<2])))
            }
        }
    }

    @Test func reentrantAccessDoesNotDeadlock() {
        let secret = SecretBytes(utf8: "abc")
        let nested = secret.withUnsafeBytes { _ in
            secret.withUnsafeBytes { $0.count } + (secret == secret.copy() ? 1 : 0)
        }
        #expect(nested == 4)
    }

    @Test func concurrentComparisonsAndWipesAreSafe() async {
        let lhs = SecretBytes(utf8: "concurrent")
        let rhs = SecretBytes(utf8: "concurrent")
        let iterations = 200
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask { _ = lhs == rhs }
                group.addTask { _ = rhs == lhs }
            }
            group.addTask { lhs.wipe() }
        }
        #expect(lhs.isWiped)
        #expect(lhs != rhs)
    }

    @Test func throwingBodiesPropagateTypedErrors() {
        struct Marker: Error, Equatable {}
        let secret = SecretBytes(utf8: "x")
        #expect(throws: Marker()) {
            try secret.withUnsafeBytes { (_) throws(Marker) -> Void in throw Marker() }
        }
    }
}
