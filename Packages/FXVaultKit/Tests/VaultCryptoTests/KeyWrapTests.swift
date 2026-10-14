import CryptoKit
import Foundation
import Testing
import VaultCore
@testable import VaultCrypto

@Suite("KeyWrap and KeyCheckValue")
struct KeyWrapTests {
    let password = "correct battery staple horse 42"
    let keys: UnlockedKeys
    let wrap: KeyWrapModel

    init() throws {
        keys = try TestData.keys()
        wrap = try KeyWrap.wrap(keys, password: password, policy: .testing, deriver: FakeKeyDeriver())
    }

    private func unwrap(
        _ wrap: KeyWrapModel,
        password: String? = nil,
        context: VaultKeyContext? = nil,
        policy: KDFPolicy = .testing,
        deriver: some PasswordKeyDeriving = FakeKeyDeriver()
    ) throws -> UnlockedKeys {
        try KeyWrap.unwrap(
            wrap,
            password: password ?? self.password,
            context: context ?? keys.context,
            policy: policy,
            deriver: deriver
        )
    }

    private func modified(
        _ wrap: KeyWrapModel,
        kdfAlgorithm: KDFAlgorithm? = nil,
        kdfParameters: KDFParameters?? = .none,
        salt: Data?? = .none,
        wrappedDEK: Data? = nil,
        dekVersion: UInt32? = nil,
        method: KeyWrapMethod? = nil
    ) -> KeyWrapModel {
        KeyWrapModel(
            method: method ?? wrap.method,
            kdfAlgorithm: kdfAlgorithm ?? wrap.kdfAlgorithm,
            kdfParameters: kdfParameters ?? wrap.kdfParameters,
            salt: salt ?? wrap.salt,
            wrappedDEK: wrappedDEK ?? wrap.wrappedDEK,
            dekVersion: dekVersion ?? wrap.dekVersion
        )
    }

    // MARK: Layout

    @Test func passwordWrapLayout() {
        #expect(wrap.method == .password)
        #expect(wrap.kdfAlgorithm == .argon2id13)
        #expect(wrap.kdfParameters == KDFParameters.testing)
        #expect(wrap.salt?.count == Limits.kdfSaltBytes)
        #expect(wrap.dekVersion == keys.dekVersion)
        #expect(wrap.wrappedDEK.count == 62)
        #expect(wrap.wrappedDEK[0] == 0x01)
        #expect(wrap.wrappedDEK[1] == 0x01)
    }

    @Test func freshSaltAndNonceEveryWrap() throws {
        let again = try KeyWrap.wrap(keys, password: password, policy: .testing, deriver: FakeKeyDeriver())
        #expect(again.salt != wrap.salt)
        #expect(again.wrappedDEK.subdata(in: 2..<14) != wrap.wrappedDEK.subdata(in: 2..<14))
    }

    @Test func wrapUsesThePolicyParametersAndNFCPassword() throws {
        let spy = SpyKeyDeriver()
        let decomposed = "Contrasen\u{0303}a segura 2026!"
        _ = try KeyWrap.wrap(keys, password: decomposed, policy: .testing, deriver: spy)
        let call = try #require(spy.calls.first)
        #expect(spy.calls.count == 1)
        #expect(call.opsLimit == KDFParameters.testing.opsLimit)
        #expect(call.memLimitBytes == KDFParameters.testing.memLimitBytes)
        #expect(call.passphrase == Data("Contrase\u{00F1}a segura 2026!".utf8))
    }

    // MARK: Round trips

    @Test func passwordRoundTrip() throws {
        let unwrapped = try unwrap(wrap)
        #expect(unwrapped.matches(keys.context))
        #expect(unwrapped.kcv == keys.kcv)
        let field = TestData.field()
        let blob = try keys.seal(SecretBytes(utf8: "value"), for: field)
        #expect(try unwrapped.open(blob, for: field).utf8String() == "value")
    }

    @Test func decomposedPasswordUnlocksComposedWrap() throws {
        let composed = "Producci\u{00F3}n segura 2026"
        let wrap = try KeyWrap.wrap(keys, password: composed, policy: .testing, deriver: FakeKeyDeriver())
        let unwrapped = try unwrap(wrap, password: "Produccio\u{0301}n segura 2026")
        #expect(unwrapped.kcv == keys.kcv)
    }

    @Test func recoveryRoundTripAndWrongKey() throws {
        let recoveryKey = RecoveryKey.generate()
        let wrap = try KeyWrap.wrap(keys, recoveryKey: recoveryKey)
        #expect(wrap.method == .recovery)
        #expect(wrap.kdfAlgorithm == .hkdfSHA256)
        #expect(wrap.kdfParameters == nil)
        #expect(wrap.salt == nil)
        #expect(wrap.wrappedDEK.count == KeyWrap.wrappedDEKBytes)

        let parsed = try RecoveryKey(parsing: recoveryKey.formatted)
        let unwrapped = try KeyWrap.unwrap(wrap, recoveryKey: parsed, context: keys.context)
        #expect(unwrapped.kcv == keys.kcv)

        #expect(throws: VaultError.invalidRecoveryKey) {
            try KeyWrap.unwrap(wrap, recoveryKey: RecoveryKey.generate(), context: keys.context)
        }
        #expect(throws: VaultError.corrupted(.kdfParametersOutOfBounds)) {
            try KeyWrap.unwrap(self.modified(wrap, salt: .some(Data(count: 16))), recoveryKey: parsed, context: keys.context)
        }
    }

    // MARK: Wrong password and tampering after the KDF

    @Test func wrongPasswordIsReported() {
        #expect(throws: VaultError.wrongPassword) {
            try self.unwrap(self.wrap, password: self.password + "!")
        }
        #expect(throws: VaultError.wrongPassword) {
            try self.unwrap(self.wrap, password: "")
        }
    }

    /// In-bounds changes to the stored row reach the KDF but fail the AAD, which is
    /// indistinguishable from a wrong password (and cannot be used to weaken the KDF).
    @Test func inBoundsTamperFailsAuthentication() throws {
        let otherVault = VaultKeyContext(vaultID: Data(repeating: 0x61, count: 16), dekVersion: keys.dekVersion, kcv: keys.kcv)
        let cases: [(String, KeyWrapModel, VaultKeyContext)] = [
            ("ops", modified(wrap, kdfParameters: .some(KDFParameters(opsLimit: 2, memLimitBytes: KDFParameters.testingMemoryBytes))), keys.context),
            ("mem", modified(wrap, kdfParameters: .some(KDFParameters(opsLimit: 1, memLimitBytes: 2 * KDFParameters.testingMemoryBytes))), keys.context),
            ("salt", modified(wrap, salt: .some(KeyHierarchy.generateSalt())), keys.context),
            ("nonce", modified(wrap, wrappedDEK: wrap.wrappedDEK.flipping(byteAt: 2)), keys.context),
            ("ciphertext", modified(wrap, wrappedDEK: wrap.wrappedDEK.flipping(byteAt: 14)), keys.context),
            ("tag", modified(wrap, wrappedDEK: wrap.wrappedDEK.flipping(byteAt: 61)), keys.context),
            ("vault id", wrap, otherVault),
            ("dek version", modified(wrap, dekVersion: 2), VaultKeyContext(vaultID: keys.vaultID, dekVersion: 2, kcv: keys.kcv)),
        ]
        for (label, tampered, context) in cases {
            let spy = SpyKeyDeriver()
            #expect(throws: VaultError.wrongPassword, "\(label)") {
                try self.unwrap(tampered, context: context, deriver: spy)
            }
            #expect(spy.calls.count == 1, "\(label) runs the KDF once")
        }
    }

    // MARK: Rejected before the KDF (spy is never called)

    @Test func outOfBoundsParametersAreRejectedBeforeTheKDF() {
        let cases: [(String, KeyWrapModel)] = [
            ("ops above max", modified(wrap, kdfParameters: .some(KDFParameters(opsLimit: 11, memLimitBytes: KDFParameters.testingMemoryBytes)))),
            ("ops zero", modified(wrap, kdfParameters: .some(KDFParameters(opsLimit: 0, memLimitBytes: KDFParameters.testingMemoryBytes)))),
            ("mem above 1 GiB", modified(wrap, kdfParameters: .some(KDFParameters(opsLimit: 1, memLimitBytes: 1_073_741_825)))),
            ("mem huge", modified(wrap, kdfParameters: .some(KDFParameters(opsLimit: 1, memLimitBytes: .max)))),
            ("mem below min", modified(wrap, kdfParameters: .some(KDFParameters(opsLimit: 1, memLimitBytes: 8_388_607)))),
            ("no parameters", modified(wrap, kdfParameters: .some(nil))),
            ("short salt", modified(wrap, salt: .some(Data(count: 15)))),
            ("long salt", modified(wrap, salt: .some(Data(count: 17)))),
            ("no salt", modified(wrap, salt: .some(nil))),
            ("hkdf algorithm", modified(wrap, kdfAlgorithm: .hkdfSHA256)),
        ]
        for (label, tampered) in cases {
            let spy = SpyKeyDeriver()
            #expect(throws: VaultError.corrupted(.kdfParametersOutOfBounds), "\(label)") {
                try self.unwrap(tampered, deriver: spy)
            }
            #expect(spy.calls.isEmpty, "\(label) must not reach the KDF")
        }
    }

    @Test func productionBoundsRejectTestingParameters() {
        let spy = SpyKeyDeriver()
        #expect(throws: VaultError.corrupted(.kdfParametersOutOfBounds)) {
            try self.unwrap(self.wrap, policy: .production, deriver: spy)
        }
        #expect(spy.calls.isEmpty)
    }

    @Test func malformedWrapsAreRejectedBeforeTheKDF() {
        var futureFormat = wrap.wrappedDEK
        futureFormat[0] = 0x02
        var zeroFormat = wrap.wrappedDEK
        zeroFormat[0] = 0x00
        var otherAEAD = wrap.wrappedDEK
        otherAEAD[1] = 0x02
        let malformedContext = VaultKeyContext(vaultID: Data(count: 15), dekVersion: 1, kcv: keys.kcv)
        let cases: [(String, KeyWrapModel, VaultKeyContext, VaultError)] = [
            ("short", modified(wrap, wrappedDEK: wrap.wrappedDEK.dropLast()), keys.context, .corrupted(.invalidWrapFormat)),
            ("long", modified(wrap, wrappedDEK: wrap.wrappedDEK + Data([0])), keys.context, .corrupted(.invalidWrapFormat)),
            ("future format", modified(wrap, wrappedDEK: futureFormat), keys.context, .corrupted(.unsupportedFormatVersion)),
            ("zero format", modified(wrap, wrappedDEK: zeroFormat), keys.context, .corrupted(.invalidWrapFormat)),
            ("aead", modified(wrap, wrappedDEK: otherAEAD), keys.context, .corrupted(.invalidWrapFormat)),
            ("version mismatch", modified(wrap, dekVersion: 7), keys.context, .corrupted(.invalidWrapFormat)),
            ("recovery row", modified(wrap, method: .recovery), keys.context, .corrupted(.missingKeyWrap)),
            ("bad vault row", wrap, malformedContext, .corrupted(.missingVaultRecord)),
        ]
        for (label, tampered, context, expected) in cases {
            let spy = SpyKeyDeriver()
            #expect(throws: expected, "\(label)") {
                try self.unwrap(tampered, context: context, deriver: spy)
            }
            #expect(spy.calls.isEmpty, "\(label) must not reach the KDF")
        }
    }

    // MARK: Key-check value

    @Test func kcvMismatchIsCorruption() throws {
        let otherKeys = try TestData.keys()
        let context = VaultKeyContext(vaultID: keys.vaultID, dekVersion: keys.dekVersion, kcv: otherKeys.kcv)
        #expect(throws: VaultError.corrupted(.keyCheckMismatch)) {
            try self.unwrap(self.wrap, context: context)
        }
        #expect(keys.kcv.count == Limits.kcvBytes)
        #expect(keys.kcv != otherKeys.kcv)
    }

    @Test func kdfFailurePropagates() {
        #expect(throws: CryptoError.kdfFailed) {
            try self.unwrap(self.wrap, deriver: FailingKeyDeriver())
        }
    }

    // MARK: Stored columns

    @Test func storedColumnsRoundTrip() throws {
        let stored = try KeyWrapModel(
            storedMethod: wrap.method.rawValue,
            kdfAlgorithm: wrap.storedKDFAlgorithm,
            opsLimit: wrap.storedOpsLimit,
            memLimitBytes: wrap.storedMemLimitBytes,
            salt: wrap.salt,
            wrappedDEK: wrap.wrappedDEK,
            dekVersion: wrap.storedDEKVersion
        )
        #expect(stored == wrap)
        #expect(wrap.storedKDFAlgorithm == 1)

        let recovery = try KeyWrap.wrap(keys, recoveryKey: RecoveryKey.generate())
        #expect(recovery.storedOpsLimit == nil)
        #expect(recovery.storedMemLimitBytes == nil)
        #expect(recovery.storedKDFAlgorithm == 2)
    }

    @Test func storedColumnsRejectImpossibleValues() {
        func make(
            method: String = "password",
            algorithm: Int64 = 1,
            ops: Int64? = 3,
            mem: Int64? = 268_435_456,
            version: Int64 = 1
        ) throws(VaultError) -> KeyWrapModel {
            try KeyWrapModel(
                storedMethod: method, kdfAlgorithm: algorithm, opsLimit: ops, memLimitBytes: mem,
                salt: Data(count: 16), wrappedDEK: Data(count: 62), dekVersion: version
            )
        }
        #expect(throws: VaultError.corrupted(.invalidWrapFormat)) { try make(method: "touchid") }
        #expect(throws: VaultError.corrupted(.invalidWrapFormat)) { try make(version: -1) }
        #expect(throws: VaultError.corrupted(.invalidWrapFormat)) { try make(version: Int64(UInt32.max) + 1) }
        #expect(throws: VaultError.corrupted(.kdfParametersOutOfBounds)) { try make(algorithm: 3) }
        #expect(throws: VaultError.corrupted(.kdfParametersOutOfBounds)) { try make(algorithm: 256) }
        #expect(throws: VaultError.corrupted(.kdfParametersOutOfBounds)) { try make(ops: -1) }
        #expect(throws: VaultError.corrupted(.kdfParametersOutOfBounds)) { try make(mem: -1) }
        #expect(throws: VaultError.corrupted(.kdfParametersOutOfBounds)) { try make(ops: nil) }
        #expect(throws: VaultError.corrupted(.kdfParametersOutOfBounds)) { try make(mem: nil) }
        #expect(throws: Never.self) { try make(ops: nil, mem: nil) }
    }

    @Test func methodRawValuesMatchTheSchema() {
        #expect(KeyWrapMethod.allCases.map(\.rawValue) == ["password", "recovery"])
        #expect(KeyWrapMethod.password.kdfAlgorithm == .argon2id13)
        #expect(KeyWrapMethod.recovery.kdfAlgorithm == .hkdfSHA256)
    }
}
