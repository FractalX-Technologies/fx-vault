import CryptoKit
import Foundation
import os
import Testing
import VaultCore
@testable import VaultCrypto

/// Real Argon2id work. Serialized so the memory-hard runs (up to 256 MiB) do not overlap (§12.1).
@Suite("Argon2id (real KDF)", .serialized)
struct Argon2idKATTests {
    @Test func matchesIndependentVectors() throws {
        let vectors = try KATVectors.load().argon2id.filter { !$0.moderate }
        #expect(vectors.count >= 4)
        for vector in vectors {
            let password = Argon2id.normalizedPassword(vector.text)
            #expect(password.withUnsafeBytes { Data($0) }.hex == vector.pwUtf8Hex, "NFC bytes \(vector.label)")
            let key = try Argon2id.deriveKey(
                password: password,
                salt: try hexData(vector.saltHex),
                parameters: KDFParameters(opsLimit: vector.ops, memLimitBytes: vector.memBytes)
            )
            #expect(key.rawData.hex == vector.outHex, "Argon2id \(vector.label)")
        }
    }

    @Test func deriverMatchesDirectCall() throws {
        let vector = try #require(try KATVectors.load().argon2id.first { $0.label == "ascii" })
        let key = try Argon2idKeyDeriver().deriveKey(
            passphrase: SecretBytes(try hexData(vector.pwUtf8Hex)),
            salt: try hexData(vector.saltHex),
            opsLimit: vector.ops,
            memLimitBytes: vector.memBytes
        )
        #expect(key.rawData.hex == vector.outHex)
    }

    @Test func composedAndDecomposedPasswordsDeriveTheSameKey() throws {
        let composed = "Contrase\u{00F1}a-Producci\u{00F3}n"
        let decomposed = "Contrasen\u{0303}a-Produccio\u{0301}n"
        // Swift `==` is canonical equivalence; the scalars (and UTF-8 bytes) differ.
        #expect(composed.unicodeScalars.count != decomposed.unicodeScalars.count)
        let salt = KeyHierarchy.generateSalt()
        let lhs = try Argon2id.deriveKey(password: Argon2id.normalizedPassword(composed), salt: salt, parameters: .testing)
        let rhs = try Argon2id.deriveKey(password: Argon2id.normalizedPassword(decomposed), salt: salt, parameters: .testing)
        #expect(lhs == rhs)

        let otherSalt = try Argon2id.deriveKey(
            password: Argon2id.normalizedPassword(composed),
            salt: KeyHierarchy.generateSalt(),
            parameters: .testing
        )
        #expect(lhs != otherSalt)
    }

    /// The password-wrap vector opened end to end with the real KDF and `.testing` bounds.
    @Test func passwordWrapUnwrapsWithRealArgon2id() throws {
        let vector = try KATVectors.load().wrap.password
        let vaultID = try hexData(vector.vaultIdHex)
        let dek = SymmetricKey(data: try hexData(vector.dekHex))
        let wrap = KeyWrapModel(
            method: .password,
            kdfAlgorithm: .argon2id13,
            kdfParameters: KDFParameters(opsLimit: vector.ops, memLimitBytes: vector.memBytes),
            salt: try hexData(vector.saltHex),
            wrappedDEK: try hexData(vector.wrappedHex),
            dekVersion: vector.dekVersion
        )
        let context = VaultKeyContext(vaultID: vaultID, dekVersion: vector.dekVersion, kcv: KeyCheckValue.compute(for: dek))
        let keys = try KeyWrap.unwrap(wrap, password: vector.text, context: context, policy: .testing)
        #expect(keys.material.dek.rawData.hex == vector.dekHex)

        // The vector's password has non-ASCII letters: the decomposed spelling must also unlock.
        let decomposed = vector.text.decomposedStringWithCanonicalMapping
        #expect(decomposed.unicodeScalars.count != vector.text.unicodeScalars.count)
        let again = try KeyWrap.unwrap(wrap, password: decomposed, context: context, policy: .testing)
        #expect(again.kcv == context.kcv)
    }

    /// The production cost (3 passes, 256 MiB). Checks the moderate vector and records the time
    /// for information only (§12.1, D8); it never fails on speed.
    @Test func moderateVectorAndTiming() throws {
        let vector = try #require(try KATVectors.load().argon2id.first { $0.moderate })
        #expect(vector.ops == KDFParameters.moderate.opsLimit)
        #expect(vector.memBytes == KDFParameters.moderate.memLimitBytes)
        let clock = ContinuousClock()
        let start = clock.now
        let key = try Argon2id.deriveKey(
            password: Argon2id.normalizedPassword(vector.text),
            salt: try hexData(vector.saltHex),
            parameters: .moderate
        )
        let elapsed = clock.now - start
        #expect(key.rawData.hex == vector.outHex)
        TestData.logger.info("Argon2id moderate (3 passes, 256 MiB) took \(elapsed, privacy: .public)")
    }
}

@Suite("Argon2id input checks")
struct Argon2idInputTests {
    @Test(arguments: [0, 15, 17, 32])
    func rejectsWrongSaltLength(length: Int) {
        #expect(throws: CryptoError.invalidKDFInput) {
            try Argon2id.deriveKey(
                password: SecretBytes(utf8: "irrelevant"),
                salt: Data(repeating: 1, count: length),
                parameters: .testing
            )
        }
    }

    @Test(arguments: [
        KDFParameters(opsLimit: 0, memLimitBytes: KDFParameters.testingMemoryBytes),
        KDFParameters(opsLimit: 1, memLimitBytes: 0),
        KDFParameters(opsLimit: 1, memLimitBytes: 4096),
        KDFParameters(opsLimit: 1, memLimitBytes: UInt64.max),
    ])
    func rejectsParametersOutsideLibsodiumLimits(parameters: KDFParameters) {
        #expect(throws: CryptoError.invalidKDFInput) {
            try Argon2id.deriveKey(
                password: SecretBytes(utf8: "irrelevant"),
                salt: KeyHierarchy.generateSalt(),
                parameters: parameters
            )
        }
    }

    @Test func normalizationProducesNFCBytes() {
        let decomposed = "e\u{0301}"
        let normalized = Argon2id.normalizedPassword(decomposed)
        #expect(normalized.withUnsafeBytes { Data($0) } == Data("\u{00E9}".utf8))
        #expect(normalized.description == SecretBytes.redacted)
    }
}

@Suite("KDF parameters and bounds")
struct KDFParametersTests {
    @Test func presetsMatchThePlan() {
        #expect(KDFParameters.moderate == KDFParameters(opsLimit: 3, memLimitBytes: 268_435_456))
        #expect(KDFParameters.testing == KDFParameters(opsLimit: 1, memLimitBytes: 8_388_608))
        #expect(KDFPolicy.production.parameters == .moderate)
        #expect(KDFPolicy.production.bounds == .password)
        #expect(KDFPolicy.testing.parameters == .testing)
    }

    @Test func passwordBoundsMatchSection52() {
        let bounds = KDFBounds.password
        let salt = Limits.kdfSaltBytes
        #expect(bounds.contains(.moderate, saltCount: salt))
        #expect(bounds.contains(KDFParameters(opsLimit: 2, memLimitBytes: 67_108_864), saltCount: salt))
        #expect(bounds.contains(KDFParameters(opsLimit: 10, memLimitBytes: 1_073_741_824), saltCount: salt))
        #expect(!bounds.contains(KDFParameters(opsLimit: 1, memLimitBytes: 268_435_456), saltCount: salt))
        #expect(!bounds.contains(KDFParameters(opsLimit: 11, memLimitBytes: 268_435_456), saltCount: salt))
        #expect(!bounds.contains(KDFParameters(opsLimit: 3, memLimitBytes: 67_108_863), saltCount: salt))
        #expect(!bounds.contains(KDFParameters(opsLimit: 3, memLimitBytes: 1_073_741_825), saltCount: salt))
        #expect(!bounds.contains(.moderate, saltCount: salt - 1))
        #expect(!bounds.contains(.testing, saltCount: salt))
        #expect(KDFBounds.testing.contains(.testing, saltCount: salt))
    }

    @Test func policyRejectsParametersOutsideItsBounds() {
        #expect(KDFPolicy(parameters: .testing, bounds: .password) == nil)
        #expect(KDFPolicy(parameters: .moderate, bounds: .password) == .production)
    }

    @Test func algorithmRawValuesMatchTheSchema() {
        #expect(KDFAlgorithm.argon2id13.rawValue == 1)
        #expect(KDFAlgorithm.hkdfSHA256.rawValue == 2)
    }
}
