import CryptoKit
import Foundation
import Testing
import VaultCore
@testable import VaultCrypto

/// Byte-exact agreement with vectors generated independently in Python (argon2-cffi and
/// pyca/cryptography, Fixtures/kat/generate_kat.py). Everything that runs the real Argon2id
/// lives in `Argon2idKATTests` (serialized, §12.1).
@Suite("Known-answer vectors")
struct KATTests {
    let vectors: KATVectors

    init() throws {
        vectors = try KATVectors.load()
    }

    // MARK: Key hierarchy (§5.1)

    @Test func hkdfFieldAndFingerprintKeys() throws {
        let hierarchy = vectors.hierarchy
        let dek = SymmetricKey(data: try hexData(hierarchy.dekHex))
        let vaultID = try hexData(hierarchy.vaultIdHex)
        #expect(KeyHierarchy.fieldKey(dek: dek, vaultID: vaultID).rawData.hex == hierarchy.kFieldHex)
        #expect(KeyHierarchy.fingerprintKey(dek: dek, vaultID: vaultID).rawData.hex == hierarchy.kFpHex)
    }

    @Test func keyCheckValue() throws {
        let hierarchy = vectors.hierarchy
        let dek = SymmetricKey(data: try hexData(hierarchy.dekHex))
        #expect(KeyCheckValue.compute(for: dek).hex == hierarchy.kcvHex)
        #expect(KeyCheckValue.matches(dek, expected: try hexData(hierarchy.kcvHex)))

        let keys = UnlockedKeys(dek: dek, vaultID: try hexData(hierarchy.vaultIdHex), dekVersion: 1)
        #expect(keys.kcv.hex == hierarchy.kcvHex)
    }

    @Test func recoveryKEK() throws {
        let hierarchy = vectors.hierarchy
        let recoveryKey = RecoveryKey(material: SecretBytes(try hexData(hierarchy.recoveryMaterialHex)))
        let kek = KeyHierarchy.recoveryKEK(recoveryKey: recoveryKey, vaultID: try hexData(hierarchy.vaultIdHex))
        #expect(kek.rawData.hex == hierarchy.recoveryKekHex)
    }

    @Test func fingerprint() throws {
        let vector = vectors.hierarchy.fingerprint
        let rowID = try #require(ConfigItemID(uuidString: vector.row))
        let key = SymmetricKey(data: try hexData(vectors.hierarchy.kFpHex))
        let value = SecretBytes(try hexData(vector.valueHex))
        #expect(ValueFingerprinter.fingerprint(of: value, rowID: rowID, key: key).hex == vector.outHex)

        let keys = UnlockedKeys(
            dek: SymmetricKey(data: try hexData(vectors.hierarchy.dekHex)),
            vaultID: try hexData(vectors.hierarchy.vaultIdHex),
            dekVersion: 1
        )
        #expect(keys.fingerprint(value, rowID: rowID).hex == vector.outHex)
    }

    // MARK: Field encryption (§5.4)

    @Test func fieldAADAndBlobs() throws {
        for vector in vectors.field {
            let field = try fieldAAD(vector)
            let aad = field.encoded(dekVersion: vector.dekVersion)
            #expect(aad.hex == vector.aadHex, "AAD \(vector.label)")

            let key = SymmetricKey(data: try hexData(vector.aesKHex))
            let nonce = try AES.GCM.Nonce(data: try hexData(vector.nonceHex))
            let plaintext = SecretBytes(try hexData(vector.plainHex))
            let blob = try FieldCipher.seal(plaintext, key: key, aad: aad, nonce: nonce)
            #expect(blob.hex == vector.blobHex, "blob \(vector.label)")

            let opened = try FieldCipher.open(try hexData(vector.blobHex), key: key, aad: aad)
            #expect(opened.withUnsafeBytes { Data($0) }.hex == vector.plainHex, "open \(vector.label)")
        }
    }

    @Test func fieldBlobsOpenThroughUnlockedKeys() throws {
        let keys = UnlockedKeys(
            dek: SymmetricKey(data: try hexData(vectors.hierarchy.dekHex)),
            vaultID: try hexData(vectors.hierarchy.vaultIdHex),
            dekVersion: 1
        )
        let vector = try #require(vectors.field.first { $0.dekVersion == 1 })
        // The field vectors use K_field of the hierarchy vector, so the DEK path must agree.
        #expect(vector.aesKHex == vectors.hierarchy.kFieldHex)
        let opened = try keys.open(try hexData(vector.blobHex), for: try fieldAAD(vector))
        #expect(opened.withUnsafeBytes { Data($0) }.hex == vector.plainHex)
    }

    @Test func folderFieldAADAndBlobs() throws {
        #expect(!vectors.folderField.isEmpty)
        let keys = UnlockedKeys(
            dek: SymmetricKey(data: try hexData(vectors.hierarchy.dekHex)),
            vaultID: try hexData(vectors.hierarchy.vaultIdHex),
            dekVersion: 1
        )
        for vector in vectors.folderField {
            let field = FolderFieldAAD(
                rowID: try #require(ConfigItemID(uuidString: vector.row)),
                folderID: try #require(FolderID(uuidString: vector.folder)),
                kind: try #require(ConfigKind(rawValue: vector.kind)),
                name: vector.name
            )
            let aad = field.encoded(dekVersion: vector.dekVersion)
            #expect(aad.hex == vector.aadHex, "AAD \(vector.label)")

            let key = SymmetricKey(data: try hexData(vector.aesKHex))
            let nonce = try AES.GCM.Nonce(data: try hexData(vector.nonceHex))
            let blob = try FieldCipher.seal(SecretBytes(try hexData(vector.plainHex)), key: key, aad: aad, nonce: nonce)
            #expect(blob.hex == vector.blobHex, "blob \(vector.label)")
            if vector.dekVersion == 1 {
                let opened = try keys.open(try hexData(vector.blobHex), for: field)
                #expect(opened.withUnsafeBytes { Data($0) }.hex == vector.plainHex, "open \(vector.label)")
                // A folder blob never opens as a repository item with the same ids and name.
                let asItem = FieldAAD(
                    location: .configItemValue,
                    rowID: field.rowID,
                    repositoryID: RepoID(field.folderID.uuid),
                    environmentID: nil,
                    kind: field.kind,
                    name: field.name
                )
                #expect(throws: VaultError.self) { try keys.open(try hexData(vector.blobHex), for: asItem) }
            }
        }
    }

    @Test func destinationFieldAADAndBlobs() throws {
        #expect(!vectors.destinationField.isEmpty)
        let keys = UnlockedKeys(
            dek: SymmetricKey(data: try hexData(vectors.hierarchy.dekHex)),
            vaultID: try hexData(vectors.hierarchy.vaultIdHex),
            dekVersion: 1
        )
        for vector in vectors.destinationField {
            let field = DestinationFieldAAD(
                rowID: try #require(ConfigItemID(uuidString: vector.row)),
                destinationID: try #require(DestinationID(uuidString: vector.destination)),
                kind: try #require(ConfigKind(rawValue: vector.kind)),
                name: vector.name
            )
            let aad = field.encoded(dekVersion: vector.dekVersion)
            #expect(aad.hex == vector.aadHex, "AAD \(vector.label)")

            let key = SymmetricKey(data: try hexData(vector.aesKHex))
            let nonce = try AES.GCM.Nonce(data: try hexData(vector.nonceHex))
            let blob = try FieldCipher.seal(SecretBytes(try hexData(vector.plainHex)), key: key, aad: aad, nonce: nonce)
            #expect(blob.hex == vector.blobHex, "blob \(vector.label)")
            if vector.dekVersion == 1 {
                let opened = try keys.open(try hexData(vector.blobHex), for: field)
                #expect(opened.withUnsafeBytes { Data($0) }.hex == vector.plainHex, "open \(vector.label)")
                // A destination blob never opens as a repository or folder item with the same ids
                // and name.
                let asItem = FieldAAD(
                    location: .configItemValue,
                    rowID: field.rowID,
                    repositoryID: RepoID(field.destinationID.uuid),
                    environmentID: nil,
                    kind: field.kind,
                    name: field.name
                )
                let asFolderItem = FolderFieldAAD(
                    rowID: field.rowID,
                    folderID: FolderID(field.destinationID.uuid),
                    kind: field.kind,
                    name: field.name
                )
                #expect(throws: VaultError.self) { try keys.open(try hexData(vector.blobHex), for: asItem) }
                #expect(throws: VaultError.self) { try keys.open(try hexData(vector.blobHex), for: asFolderItem) }
            }
        }
    }

    // MARK: DEK wraps (§5.2)

    @Test func passwordWrapLayoutAndAAD() throws {
        let vector = vectors.wrap.password
        let parameters = KDFParameters(opsLimit: vector.ops, memLimitBytes: vector.memBytes)
        let salt = try hexData(vector.saltHex)
        let vaultID = try hexData(vector.vaultIdHex)
        let aad = KeyWrap.additionalData(
            method: .password,
            vaultID: vaultID,
            dekVersion: vector.dekVersion,
            kdfParameters: parameters,
            salt: salt
        )
        #expect(aad.hex == vector.aadHex)

        let keys = UnlockedKeys(dek: SymmetricKey(data: try hexData(vector.dekHex)), vaultID: vaultID, dekVersion: vector.dekVersion)
        let wrap = try KeyWrap.wrap(
            keys,
            method: .password,
            kdfParameters: parameters,
            salt: salt,
            kek: SymmetricKey(data: try hexData(vector.kekHex)),
            nonce: try AES.GCM.Nonce(data: try hexData(vector.nonceHex))
        )
        #expect(wrap.wrappedDEK.hex == vector.wrappedHex)
    }

    @Test func recoveryWrap() throws {
        let vector = vectors.wrap.recovery
        let vaultID = try hexData(vector.vaultIdHex)
        let aad = KeyWrap.additionalData(
            method: .recovery,
            vaultID: vaultID,
            dekVersion: vector.dekVersion,
            kdfParameters: nil,
            salt: nil
        )
        #expect(aad.hex == vector.aadHex)

        let dek = SymmetricKey(data: try hexData(vector.dekHex))
        let keys = UnlockedKeys(dek: dek, vaultID: vaultID, dekVersion: vector.dekVersion)
        let recoveryKey = RecoveryKey(material: SecretBytes(try hexData(vector.materialHex)))
        let wrap = try KeyWrap.wrap(keys, recoveryKey: recoveryKey, nonce: try AES.GCM.Nonce(data: try hexData(vector.nonceHex)))
        #expect(wrap.wrappedDEK.hex == vector.wrappedHex)

        let context = VaultKeyContext(vaultID: vaultID, dekVersion: vector.dekVersion, kcv: KeyCheckValue.compute(for: dek))
        let unwrapped = try KeyWrap.unwrap(wrap, recoveryKey: recoveryKey, context: context)
        #expect(unwrapped.material.dek.rawData.hex == vector.dekHex)
    }

    // MARK: Recovery text (§5.3)

    @Test func recoveryKeyText() throws {
        for vector in vectors.recovery {
            let key = RecoveryKey(material: SecretBytes(try hexData(vector.materialHex)))
            #expect(key.text == vector.text)
            #expect(key.groups == vector.groups)
            #expect(key.formatted == vector.groups.joined(separator: "-"))

            let parsed = try RecoveryKey(parsing: vector.text)
            #expect(parsed.withUnsafeBytes { Data($0) }.hex == vector.materialHex)
        }
    }

    @Test func crockfordEncoding() throws {
        for vector in vectors.crockford {
            let bytes = try hexData(vector.inHex)
            #expect(CrockfordBase32.encode(bytes) == vector.text)
            let decoded = try #require(CrockfordBase32.decode(vector.text))
            #expect(decoded.withUnsafeBytes { Data($0) } == bytes)
        }
    }

    // MARK: Helpers

    private func fieldAAD(_ vector: KATVectors.FieldVector) throws -> FieldAAD {
        let location = try #require(FieldLocation.allCases.first { $0.table == vector.table && $0.column == vector.column })
        return FieldAAD(
            location: location,
            rowID: try #require(ConfigItemID(uuidString: vector.row)),
            repositoryID: try #require(RepoID(uuidString: vector.repo)),
            environmentID: try vector.env.map { try #require(EnvironmentID(uuidString: $0)) },
            kind: try #require(ConfigKind(rawValue: vector.kind)),
            name: vector.name
        )
    }
}
