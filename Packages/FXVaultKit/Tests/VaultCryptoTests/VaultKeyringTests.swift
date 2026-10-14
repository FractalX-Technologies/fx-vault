import CryptoKit
import Foundation
import Testing
import VaultCore
@testable import VaultCrypto

@Suite("VaultKeyring")
struct VaultKeyringTests {
    @Test func startsLockedAndThrowsLocked() {
        let keyring = VaultKeyring()
        #expect(keyring.isLocked)
        #expect(keyring.generation == 0)
        #expect(throws: VaultError.locked) {
            try keyring.withKeys { $0.dekVersion }
        }
    }

    @Test func installThenUse() throws {
        let keyring = VaultKeyring()
        let keys = try TestData.keys()
        let generation = keyring.install(keys)
        #expect(!keyring.isLocked)
        #expect(generation == 1)
        let seen = try keyring.withKeys { ($0.kcv, $0.generation) }
        #expect(seen.0 == keys.kcv)
        #expect(seen.1 == generation)
        try keyring.ensureCurrent(generation)
    }

    @Test func nestedWithKeysDoesNotDeadlock() throws {
        let keyring = VaultKeyring()
        keyring.install(try TestData.keys())
        let depth = try keyring.withKeys { outer in
            try keyring.withKeys { inner in
                try keyring.withKeys { innermost in
                    outer.kcv == inner.kcv && inner.kcv == innermost.kcv ? 3 : 0
                }
            }
        }
        #expect(depth == 3)
    }

    @Test func lockInsideWithKeysDoesNotDeadlockAndTakesEffect() throws {
        let keyring = VaultKeyring()
        keyring.install(try TestData.keys())
        let generation = try keyring.withKeys { keys in
            keyring.lock()
            return keys.generation
        }
        #expect(keyring.isLocked)
        #expect(throws: VaultError.locked) {
            try keyring.ensureCurrent(generation)
        }
    }

    @Test func lockThenWithKeysThrowsLocked() throws {
        let keyring = VaultKeyring()
        let first = keyring.install(try TestData.keys())
        keyring.lock()
        #expect(keyring.isLocked)
        #expect(keyring.generation == first + 1)
        #expect(throws: VaultError.locked) {
            try keyring.withKeys { $0.kcv }
        }
        #expect(throws: VaultError.locked) {
            try keyring.ensureCurrent(first)
        }
        keyring.lock()
        #expect(keyring.generation == first + 2)
    }

    @Test func reinstallInvalidatesOldGeneration() throws {
        let keyring = VaultKeyring()
        let first = keyring.install(try TestData.keys())
        let second = keyring.install(try TestData.keys())
        #expect(second > first)
        #expect(throws: VaultError.locked) {
            try keyring.ensureCurrent(first)
        }
        try keyring.ensureCurrent(second)
    }

    @Test func lockReleasesTheKeyStorage() throws {
        let keyring = VaultKeyring()
        installFreshKeys(into: keyring)
        weak let storage = keyring.keyStorageForTesting()
        #expect(storage != nil)
        _ = try keyring.withKeys { $0.kcv }
        #expect(storage != nil)
        keyring.lock()
        #expect(storage == nil)
    }

    @Test func concurrentReadersAndLockAreSafe() async throws {
        let keyring = VaultKeyring()
        keyring.install(try TestData.keys())
        let readers = 200
        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<readers {
                group.addTask {
                    if index == readers / 2 {
                        keyring.lock()
                    }
                    do {
                        return try keyring.withKeys { $0.kcv.count == Limits.kcvBytes }
                    } catch {
                        return error as? VaultError == .locked
                    }
                }
            }
            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        #expect(outcomes.count == readers)
        #expect(outcomes.allSatisfy { $0 })
        #expect(keyring.isLocked)
    }

    private func installFreshKeys(into keyring: VaultKeyring) {
        guard let keys = try? TestData.keys() else {
            Issue.record("could not create keys")
            return
        }
        keyring.install(keys)
    }
}

@Suite("UnlockedKeys and fingerprints")
struct UnlockedKeysTests {
    @Test func equalValuesInDifferentRowsHaveDifferentFingerprints() throws {
        let keys = try TestData.keys()
        let value = SecretBytes(utf8: "same value")
        let rowA = ConfigItemID()
        let rowB = ConfigItemID()
        let fingerprintA = keys.fingerprint(value, rowID: rowA)
        let fingerprintB = keys.fingerprint(value, rowID: rowB)
        #expect(fingerprintA.count == ValueFingerprinter.byteCount)
        #expect(fingerprintA != fingerprintB)
        #expect(keys.fingerprint(value, rowID: rowA) == fingerprintA)
        #expect(keys.fingerprint(SecretBytes(utf8: "other value"), rowID: rowA) != fingerprintA)
        #expect(keys.fingerprintMatches(fingerprintA, value: value, rowID: rowA))
        #expect(!keys.fingerprintMatches(fingerprintA, value: value, rowID: rowB))
        #expect(!keys.fingerprintMatches(fingerprintA.prefix(16), value: value, rowID: rowA))
    }

    @Test func fingerprintsDependOnTheVaultKey() throws {
        let value = SecretBytes(utf8: "same value")
        let row = ConfigItemID()
        #expect(try TestData.keys().fingerprint(value, rowID: row) != (try TestData.keys().fingerprint(value, rowID: row)))
    }

    @Test func purposeKeysAreSeparated() throws {
        let keys = try TestData.keys()
        let material = keys.material
        #expect(material.fieldKey != material.fingerprintKey)
        #expect(material.fieldKey != material.dek)
        let otherVault = UnlockedKeys(dek: material.dek, vaultID: Data(repeating: 0x01, count: 16), dekVersion: 1)
        #expect(otherVault.material.fieldKey != material.fieldKey)
    }

    @Test func openMapsFailuresToVaultErrors() throws {
        let keys = try TestData.keys()
        let field = TestData.field()
        var blob = try keys.seal(SecretBytes(utf8: "v"), for: field)
        #expect(throws: VaultError.corrupted(.fieldDecryptionFailed)) {
            try keys.open(blob, for: TestData.field())
        }
        #expect(throws: VaultError.corrupted(.fieldDecryptionFailed)) {
            try keys.open(Data([0x01]), for: field)
        }
        blob[blob.startIndex] = 0x02
        #expect(throws: VaultError.corrupted(.unsupportedFormatVersion)) {
            try keys.open(blob, for: field)
        }
    }

    @Test func rotationChangesDEKAndVersion() throws {
        let keys = try TestData.keys()
        let rotated = keys.rotated()
        #expect(rotated.dekVersion == keys.dekVersion + 1)
        #expect(rotated.vaultID == keys.vaultID)
        #expect(rotated.kcv != keys.kcv)
        let field = TestData.field()
        let blob = try keys.seal(SecretBytes(utf8: "value"), for: field)
        #expect(throws: VaultError.corrupted(.fieldDecryptionFailed)) {
            try rotated.open(blob, for: field)
        }
        let row = ConfigItemID()
        #expect(rotated.fingerprint(SecretBytes(utf8: "x"), rowID: row) != keys.fingerprint(SecretBytes(utf8: "x"), rowID: row))
    }

    @Test func dekExportRebuildsTheSameKeys() throws {
        let keys = try TestData.keys()
        let exported = keys.exportDEK()
        defer { exported.wipe() }
        #expect(exported.count == CryptoDomain.symmetricKeyBytes)
        let rebuilt = try UnlockedKeys(dekBytes: exported, context: keys.context)
        #expect(rebuilt.matches(keys.context))
        let field = TestData.field()
        let blob = try keys.seal(SecretBytes(utf8: "value"), for: field)
        #expect(try rebuilt.open(blob, for: field).utf8String() == "value")
    }

    @Test func dekImportChecksTheVaultRow() throws {
        let keys = try TestData.keys()
        let other = try TestData.keys()
        let exported = other.exportDEK()
        #expect(throws: VaultError.corrupted(.keyCheckMismatch)) {
            try UnlockedKeys(dekBytes: exported, context: keys.context)
        }
        #expect(throws: VaultError.corrupted(.invalidStoredValue)) {
            try UnlockedKeys(dekBytes: SecretBytes(count: 31), context: keys.context)
        }
        #expect(throws: VaultError.corrupted(.missingVaultRecord)) {
            try UnlockedKeys(
                dekBytes: exported,
                context: VaultKeyContext(vaultID: keys.vaultID, dekVersion: 1, kcv: Data(count: 15))
            )
        }
        #expect(!keys.matches(other.context))
        #expect(!keys.matches(VaultKeyContext(vaultID: keys.vaultID, dekVersion: 2, kcv: keys.kcv)))
    }

    @Test func generateValidatesTheVaultID() {
        #expect(throws: CryptoError.invalidLength(expected: 16, actual: 8)) {
            try UnlockedKeys.generate(vaultID: Data(count: 8))
        }
        #expect(KeyHierarchy.generateVaultID().count == Limits.vaultIDBytes)
        #expect(KeyHierarchy.generateVaultID() != KeyHierarchy.generateVaultID())
    }

    @Test func secureRandomFillsBuffers() {
        #expect(SecureRandom.data(count: 0).isEmpty)
        #expect(SecureRandom.data(count: 32) != SecureRandom.data(count: 32))
        #expect(SecureRandom.secretBytes(count: 32) != SecureRandom.secretBytes(count: 32))
    }
}
