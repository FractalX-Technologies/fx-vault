import CryptoKit
import Foundation
import Testing
import VaultCore
@testable import VaultCrypto

@Suite("FieldCipher and field AAD")
struct FieldCipherTests {
    let key = SymmetricKey(size: .bits256)
    let field = TestData.field()
    let dekVersion: UInt32 = 1

    private func seal(_ text: String = "FXV_FIXTURE_VALUE") throws -> Data {
        try FieldCipher.seal(SecretBytes(utf8: text), key: key, aad: field.encoded(dekVersion: dekVersion))
    }

    @Test func roundTripsEmptyAndMaximumValues() throws {
        for size in [0, 1, Limits.maxValueBytes] {
            let value = SecureRandom.secretBytes(count: size)
            let aad = field.encoded(dekVersion: dekVersion)
            let blob = try FieldCipher.seal(value, key: key, aad: aad)
            #expect(blob.count == size + FieldCipher.minimumBlobBytes)
            #expect(blob.first == FieldCipher.formatVersion)
            let opened = try FieldCipher.open(blob, key: key, aad: aad)
            #expect(opened == value)
        }
    }

    @Test func sealingTwiceUsesFreshNonces() throws {
        let first = try seal()
        let second = try seal()
        #expect(first != second)
        #expect(first.dropFirst().prefix(Limits.gcmNonceBytes) != second.dropFirst().prefix(Limits.gcmNonceBytes))
    }

    /// D11: every AAD component, including kind, scope and DEK version, is bound.
    @Test func changingAnyAADComponentFailsAuthentication() throws {
        let blob = try seal()
        let otherEnvironment = FieldAAD(
            location: field.location, rowID: field.rowID, repositoryID: field.repositoryID,
            environmentID: EnvironmentID(), kind: field.kind, name: field.name
        )
        let repositoryLevel = FieldAAD(
            location: field.location, rowID: field.rowID, repositoryID: field.repositoryID,
            environmentID: nil, kind: field.kind, name: field.name
        )
        let variants: [(String, Data)] = [
            ("location", FieldAAD(
                location: .configItemSyncedValue, rowID: field.rowID, repositoryID: field.repositoryID,
                environmentID: field.environmentID, kind: field.kind, name: field.name
            ).encoded(dekVersion: dekVersion)),
            ("row", FieldAAD(
                location: field.location, rowID: ConfigItemID(), repositoryID: field.repositoryID,
                environmentID: field.environmentID, kind: field.kind, name: field.name
            ).encoded(dekVersion: dekVersion)),
            ("repository", FieldAAD(
                location: field.location, rowID: field.rowID, repositoryID: RepoID(),
                environmentID: field.environmentID, kind: field.kind, name: field.name
            ).encoded(dekVersion: dekVersion)),
            ("environment", otherEnvironment.encoded(dekVersion: dekVersion)),
            ("scope flip to repository", repositoryLevel.encoded(dekVersion: dekVersion)),
            ("kind flip", FieldAAD(
                location: field.location, rowID: field.rowID, repositoryID: field.repositoryID,
                environmentID: field.environmentID, kind: .variable, name: field.name
            ).encoded(dekVersion: dekVersion)),
            ("name", FieldAAD(
                location: field.location, rowID: field.rowID, repositoryID: field.repositoryID,
                environmentID: field.environmentID, kind: field.kind, name: field.name + "_X"
            ).encoded(dekVersion: dekVersion)),
            ("name case", FieldAAD(
                location: field.location, rowID: field.rowID, repositoryID: field.repositoryID,
                environmentID: field.environmentID, kind: field.kind, name: field.name.lowercased()
            ).encoded(dekVersion: dekVersion)),
            ("dek version", field.encoded(dekVersion: dekVersion + 1)),
            ("empty AAD", Data()),
        ]
        for (label, aad) in variants {
            #expect(aad != field.encoded(dekVersion: dekVersion), "\(label) must change the AAD")
            #expect(throws: CryptoError.authenticationFailed, "\(label)") {
                try FieldCipher.open(blob, key: key, aad: aad)
            }
        }
    }

    @Test func tamperedNonceCiphertextOrTagFails() throws {
        let blob = try seal()
        let aad = field.encoded(dekVersion: dekVersion)
        let nonceByte = 1
        let ciphertextByte = 1 + Limits.gcmNonceBytes
        let tagByte = blob.count - 1
        for index in [nonceByte, nonceByte + Limits.gcmNonceBytes - 1, ciphertextByte, tagByte - Limits.gcmTagBytes + 1, tagByte] {
            #expect(throws: CryptoError.authenticationFailed, "byte \(index)") {
                try FieldCipher.open(blob.flipping(byteAt: index), key: key, aad: aad)
            }
        }
    }

    @Test func wrongKeyFails() throws {
        let blob = try seal()
        #expect(throws: CryptoError.authenticationFailed) {
            try FieldCipher.open(blob, key: SymmetricKey(size: .bits256), aad: field.encoded(dekVersion: dekVersion))
        }
    }

    @Test(arguments: [UInt8(0x00), 0x02, 0xFF])
    func unknownFormatByteIsRejected(format: UInt8) throws {
        var blob = try seal()
        blob[blob.startIndex] = format
        #expect(throws: CryptoError.unsupportedFormat(format)) {
            try FieldCipher.open(blob, key: key, aad: field.encoded(dekVersion: dekVersion))
        }
    }

    @Test func truncatedBlobsAreMalformed() throws {
        let aad = field.encoded(dekVersion: dekVersion)
        #expect(throws: CryptoError.malformedCiphertext) {
            try FieldCipher.open(Data(), key: key, aad: aad)
        }
        let blob = try seal("")
        #expect(throws: CryptoError.malformedCiphertext) {
            try FieldCipher.open(blob.dropLast(), key: key, aad: aad)
        }
    }

    @Test func worksOnDataSlices() throws {
        let blob = try seal()
        let padded = Data([0xAA, 0xBB]) + blob
        let slice = padded.dropFirst(2)
        let opened = try FieldCipher.open(slice, key: key, aad: field.encoded(dekVersion: dekVersion))
        #expect(opened.utf8String() == "FXV_FIXTURE_VALUE")
    }
}

@Suite("AADBuilder")
struct AADBuilderTests {
    @Test func encodesFixedWidthIntegersBigEndian() {
        var builder = AADBuilder()
        builder.append(0xAB)
        builder.append(uint32BigEndian: 0x0102_0304)
        builder.append(uint64BigEndian: 0x0102_0304_0506_0708)
        #expect(builder.data == Data([0xAB, 1, 2, 3, 4, 1, 2, 3, 4, 5, 6, 7, 8]))
    }

    @Test func lengthPrefixesFields() {
        var builder = AADBuilder()
        builder.appendLengthPrefixed("ab")
        builder.appendLengthPrefixed(Data())
        builder.appendLengthPrefixed([UInt8(0xFF)])
        #expect(builder.data == Data([0, 0, 0, 2, 0x61, 0x62, 0, 0, 0, 0, 0, 0, 0, 1, 0xFF]))
    }

    @Test func lengthPrefixesKeepNeighbouringFieldsApart() {
        var lhs = AADBuilder()
        lhs.appendLengthPrefixed("AB")
        lhs.appendLengthPrefixed("C")
        var rhs = AADBuilder()
        rhs.appendLengthPrefixed("A")
        rhs.appendLengthPrefixed("BC")
        #expect(lhs.data != rhs.data)
    }

    @Test func fieldAADLayout() throws {
        let row = try #require(ConfigItemID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let repo = try #require(RepoID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let field = FieldAAD(location: .configItemValue, rowID: row, repositoryID: repo, environmentID: nil, kind: .variable, name: "N")
        var expected = AADBuilder()
        expected.appendLengthPrefixed("fxvault/v1/field")
        expected.appendLengthPrefixed("config_items")
        expected.appendLengthPrefixed("value_ct")
        expected.appendLengthPrefixed(row.bytes)
        expected.appendLengthPrefixed(repo.bytes)
        expected.appendLengthPrefixed([UInt8]())
        expected.appendLengthPrefixed("variable")
        expected.appendLengthPrefixed("N")
        expected.append(uint32BigEndian: 9)
        #expect(field.encoded(dekVersion: 9) == expected.data)
        #expect(row.bytes.count == 16)
    }

    @Test func itemHelpersBindTheRightName() {
        let environment = EnvironmentID()
        var item = ConfigItemModel(
            repositoryID: RepoID(),
            scope: .environment(environment),
            kind: .secret,
            name: "NEW_NAME",
            valueState: .present,
            syncStatus: .added,
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            updatedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        #expect(FieldAAD.syncedValue(of: item) == nil)
        item.syncedName = "OLD_NAME"
        let value = FieldAAD.value(of: item)
        let synced = FieldAAD.syncedValue(of: item)
        #expect(value.name == "NEW_NAME")
        #expect(value.location == .configItemValue)
        #expect(value.environmentID == environment)
        #expect(synced?.name == "OLD_NAME")
        #expect(synced?.location == .configItemSyncedValue)
        #expect(synced?.rowID == item.id)
        #expect(FieldLocation.configItemSyncedValue.column == "synced_value_ct")
    }
}

/// Secret fields (v0.5.0; since 1.0 only provider connection tokens): sealed under `K_field`
/// with their own AAD. The table names below are labels, so the 0.9 ones still test the binding.
@Suite("Secret fields")
struct SecretFieldTests {
    @Test func roundTripsAndBindsTableColumnRowAndDEKVersion() throws {
        let keys = try UnlockedKeys.generate(vaultID: Data(repeating: 7, count: Limits.vaultIDBytes))
        let field = SecretFieldAAD(table: "device_identity", column: "secret_ct", rowKey: Data([1]))
        let blob = try keys.seal(SecretBytes(utf8: "device-keys"), for: field)
        let opened = try keys.open(blob, for: field)
        #expect(opened.utf8String() == "device-keys")
        opened.wipe()

        for other in [
            SecretFieldAAD(table: "teammates", column: "secret_ct", rowKey: Data([1])),
            SecretFieldAAD(table: "device_identity", column: "announce_ct", rowKey: Data([1])),
            SecretFieldAAD(table: "device_identity", column: "secret_ct", rowKey: Data([2])),
        ] {
            #expect(throws: VaultError.corrupted(.fieldDecryptionFailed)) { try keys.open(blob, for: other) }
        }
        #expect(throws: VaultError.corrupted(.fieldDecryptionFailed)) { try keys.rotated().open(blob, for: field) }
        #expect(field.encoded(dekVersion: 1).starts(with: [0, 0, 0, 23] + Array("fxvault/v1/secret-field".utf8)))
    }
}
