import CryptoKit
import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// `.fxvault` format 2 (v0.9.0): both modes, the reader order, tampering and the v1 path.
@Suite("fxvault format 2 codec")
struct FxVaultFileV2CodecTests {
    static let passphrase = SecretBytes(utf8: "abacus-abdomen-abdominal-abide-abiding-ability")
    static let payload = Data(#"{"schema":"io.fractalx.fxvault.share","schemaVersion":4,"scope":"bundle"}"#.utf8)

    /// A sender, `count` recipients, and a file the sender sealed for them.
    struct TeammatesFile {
        let sender: TeamDeviceKeys
        let recipients: [TeamDeviceKeys]
        let file: Data

        var senderKeys: [ShareTeammateKeyModel] {
            [ShareTeammateKeyModel(device: sender)]
        }
    }

    static func teammatesFile(recipientCount: Int = 2, payload: Data = payload) throws -> TeammatesFile {
        let sender = TeamDeviceKeys.generate()
        let recipients = (0..<recipientCount).map { _ in TeamDeviceKeys.generate() }
        let file = try FxVaultFileV2Codec(deriver: FakeKeyDeriver()).sealForTeammates(
            payload: SecretBytes(payload),
            sender: sender,
            recipients: recipients.map { ShareTeammateKeyModel(device: $0) }
        )
        return TeammatesFile(sender: sender, recipients: recipients, file: file)
    }

    static func open(_ file: Data, as device: TeamDeviceKeys, teammates: [ShareTeammateKeyModel]) throws -> Data {
        let opened = try FxVaultFileV2Codec(deriver: FakeKeyDeriver()).openAsTeammate(file, device: device, teammates: teammates)
        defer { opened.payload.wipe() }
        return opened.payload.withUnsafeBytes { Data($0) }
    }

    static func slotsRange(_ count: Int) -> Range<Int> {
        Limits.shareHeaderBytes..<(Limits.shareHeaderBytes + count * Limits.shareRecipientSlotBytes)
    }

    // MARK: - Passphrase mode

    @Test func passphraseModeRoundTrips() async throws {
        let codec = FxVaultFileV2Codec(deriver: FakeKeyDeriver())
        let file = try await codec.sealWithPassphrase(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        let info = try FxVaultFileV2Codec.inspect(file)
        guard case .v2Passphrase(let header) = info else {
            Issue.record("expected a passphrase file, got \(info)")
            return
        }
        #expect(info.needsPassphrase)
        #expect(header.opsLimit == UInt32(Limits.shareKDFOpsLimit))
        #expect(header.memLimitKiB == UInt32(Limits.shareKDFMemoryKiB))
        #expect(file.count == Limits.shareHeaderBytes + Self.payload.count + Limits.gcmTagBytes)
        let opened = try await codec.openWithPassphrase(file, passphrase: Self.passphrase)
        #expect(opened.withUnsafeBytes { Data($0) } == Self.payload)
    }

    @Test func everyPassphraseExportHasAFreshSaltAndNonce() async throws {
        let codec = FxVaultFileV2Codec(deriver: FakeKeyDeriver())
        let first = try await codec.sealWithPassphrase(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        let second = try await codec.sealWithPassphrase(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        let saltAndNonce = FxVaultHeaderV2Model.Offset.salt..<FxVaultHeaderV2Model.Offset.mode
        #expect(first[saltAndNonce] != second[saltAndNonce])
    }

    @Test func wrongPassphraseFails() async throws {
        let codec = FxVaultFileV2Codec(deriver: FakeKeyDeriver())
        let file = try await codec.sealWithPassphrase(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        await #expect(throws: ShareError.invalidFile) {
            _ = try await codec.openWithPassphrase(file, passphrase: SecretBytes(utf8: "other-words"))
        }
    }

    @Test func cancellationIsReported() async throws {
        let file = try await FxVaultFileV2Codec(deriver: FakeKeyDeriver())
            .sealWithPassphrase(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        await #expect(throws: ShareError.cancelled) {
            _ = try await FxVaultFileV2Codec(deriver: CancellingKeyDeriver()).openWithPassphrase(file, passphrase: Self.passphrase)
        }
    }

    @Test(arguments: 0..<64)
    func flippingAnyPassphraseHeaderByteFails(_ offset: Int) async throws {
        let codec = FxVaultFileV2Codec(deriver: FakeKeyDeriver())
        var file = try await codec.sealWithPassphrase(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        file[offset] ^= 0x01
        await #expect(throws: ShareError.invalidFile) {
            _ = try await codec.openWithPassphrase(file, passphrase: Self.passphrase)
        }
    }

    @Test func flippingPassphraseCiphertextOrTagFails() async throws {
        let codec = FxVaultFileV2Codec(deriver: FakeKeyDeriver())
        let file = try await codec.sealWithPassphrase(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        for offset in Limits.shareHeaderBytes..<file.count {
            var tampered = file
            tampered[offset] ^= 0x80
            await #expect(throws: ShareError.invalidFile) {
                _ = try await codec.openWithPassphrase(tampered, passphrase: Self.passphrase)
            }
        }
    }

    /// (description, offset, replacement bytes) for a valid passphrase-mode header.
    static let rejectedPassphraseHeaders: [(String, Int, [UInt8])] = [
        ("format version 3", 8, [0x00, 0x03]),
        ("header length 65", 10, [0x00, 0x41]),
        ("kdf id 0", 12, [0x00]),
        ("aead id 2", 13, [0x02]),
        ("ops limit 0", 14, [0, 0, 0, 0]),
        ("ops limit 11", 14, [0, 0, 0, 11]),
        ("memory 8191 KiB", 18, [0, 0, 0x1F, 0xFF]),
        ("parallelism 0", 22, [0x00]),
        ("flags 1", 23, [0x01]),
        ("mode 0", 52, [0x00]),
        ("mode 3", 52, [0x03]),
        ("mode teammates", 52, [0x02]),
        ("one recipient", 53, [0x01]),
        ("first reserved byte", 54, [0x01]),
        ("last reserved byte", 63, [0x01]),
    ]

    @Test(arguments: 0..<rejectedPassphraseHeaders.count)
    func passphraseHeaderBoundsAreRejectedBeforeTheKDF(_ index: Int) async throws {
        let (_, offset, bytes) = Self.rejectedPassphraseHeaders[index]
        var file = try await FxVaultFileV2Codec(deriver: FakeKeyDeriver())
            .sealWithPassphrase(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        file.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        let spy = SpyKeyDeriver()
        #expect(throws: ShareError.invalidFile) { _ = try FxVaultFileV2Codec.inspect(file) }
        await #expect(throws: ShareError.invalidFile) {
            _ = try await FxVaultFileV2Codec(deriver: spy).openWithPassphrase(file, passphrase: Self.passphrase)
        }
        #expect(spy.callCount == 0)
    }

    @Test func inspectingAndSizeChecksNeverDeriveAKey() async throws {
        let spy = SpyKeyDeriver()
        let codec = FxVaultFileV2Codec(deriver: spy)
        let file = try await FxVaultFileV2Codec(deriver: FakeKeyDeriver())
            .sealWithPassphrase(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        _ = try FxVaultFileV2Codec.inspect(file)
        let oversize = file + Data(count: Limits.maxShareFileV2Bytes - file.count + 1)
        let passphraseOversize = file + Data(count: Limits.maxShareFileBytes - file.count + 1)
        for bad in [oversize, passphraseOversize, file.prefix(Limits.shareHeaderBytes + Limits.gcmTagBytes - 1), Data()] {
            #expect(throws: ShareError.invalidFile) { _ = try FxVaultFileV2Codec.inspect(bad) }
            await #expect(throws: ShareError.invalidFile) {
                _ = try await codec.openWithPassphrase(bad, passphrase: Self.passphrase)
            }
        }
        #expect(spy.callCount == 0)
        _ = try await codec.openWithPassphrase(file, passphrase: Self.passphrase)
        #expect(spy.callCount == 1)
    }

    @Test func passphrasePayloadLimitIsEnforced() async throws {
        let codec = FxVaultFileV2Codec(deriver: FakeKeyDeriver())
        await #expect(throws: ShareError.payloadTooLarge) {
            _ = try await codec.sealWithPassphrase(
                payload: SecretBytes(count: Limits.maxSharePayloadBytes + 1),
                passphrase: Self.passphrase
            )
        }
    }

    // MARK: - v1 through the new entry point

    @Test func versionOneFilesStillOpen() async throws {
        let vector = try FxVaultFileCodecTests.katFile()
        #expect(try FxVaultFileV2Codec.inspect(vector.file) == .v1(vector.header))
        #expect(try FxVaultFileV2Codec.inspect(vector.file).needsPassphrase)
        let codec = FxVaultFileV2Codec(deriver: FixedKeyDeriver(key: vector.key))
        let opened = try await codec.openWithPassphrase(vector.file, passphrase: Self.passphrase)
        #expect(opened.withUnsafeBytes { Data($0) } == vector.payload)

        let sealed = try await FxVaultFileCodec(deriver: FakeKeyDeriver()).encrypt(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        let reopened = try await FxVaultFileV2Codec(deriver: FakeKeyDeriver()).openWithPassphrase(sealed, passphrase: Self.passphrase)
        #expect(reopened.withUnsafeBytes { Data($0) } == Self.payload)
    }

    @Test func theVersionOneReaderRefusesFormatTwo() async throws {
        let file = try await FxVaultFileV2Codec(deriver: FakeKeyDeriver())
            .sealWithPassphrase(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        #expect(throws: ShareError.invalidFile) { _ = try FxVaultFileCodec.inspect(file) }
    }

    @Test func modesAreNotInterchangeable() async throws {
        let teammates = try Self.teammatesFile()
        let codec = FxVaultFileV2Codec(deriver: FakeKeyDeriver())
        await #expect(throws: ShareError.invalidFile) {
            _ = try await codec.openWithPassphrase(teammates.file, passphrase: Self.passphrase)
        }
        let passphraseFile = try await codec.sealWithPassphrase(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        #expect(throws: ShareError.invalidFile) {
            _ = try codec.openAsTeammate(passphraseFile, device: teammates.recipients[0], teammates: teammates.senderKeys)
        }
        let vector = try FxVaultFileCodecTests.katFile()
        #expect(throws: ShareError.invalidFile) {
            _ = try codec.openAsTeammate(vector.file, device: teammates.recipients[0], teammates: teammates.senderKeys)
        }
    }

    // MARK: - Teammates mode

    @Test(arguments: [1, 2, Limits.maxShareRecipients])
    func teammatesModeRoundTripsForEveryRecipient(_ count: Int) throws {
        let teammates = try Self.teammatesFile(recipientCount: count)
        let info = try FxVaultFileV2Codec.inspect(teammates.file)
        guard case .v2Teammates(let header, let recipientCount) = info else {
            Issue.record("expected a teammates file, got \(info)")
            return
        }
        #expect(!info.needsPassphrase)
        #expect(recipientCount == count)
        #expect(header.recipientCount == count)
        #expect(teammates.file.count == Limits.shareHeaderBytes + count * Limits.shareRecipientSlotBytes
            + Limits.shareSenderPrefixBytes + Self.payload.count + Limits.gcmTagBytes)
        for recipient in teammates.recipients {
            let opened = try FxVaultFileV2Codec(deriver: FakeKeyDeriver())
                .openAsTeammate(teammates.file, device: recipient, teammates: teammates.senderKeys)
            #expect(opened.payload.withUnsafeBytes { Data($0) } == Self.payload)
            #expect(opened.sender == teammates.sender.deviceID)
            #expect(opened.senderAnnounceKey == teammates.sender.announceKey)
            opened.payload.wipe()
        }
    }

    @Test func slotsAreSortedAndCarryNoDeviceIDs() throws {
        let teammates = try Self.teammatesFile(recipientCount: Limits.maxShareRecipients)
        guard case .v2Teammates(let header, let count) = try FxVaultFileV2Codec.inspect(teammates.file) else {
            Issue.record("expected a teammates file")
            return
        }
        let slots = try FxVaultRecipientSlot.parseAll(teammates.file, at: Limits.shareHeaderBytes, count: count)
        #expect(zip(slots, slots.dropFirst()).allSatisfy { $0.slotID.lexicographicallyPrecedes($1.slotID) })
        let expected = Set(teammates.recipients.map { FxVaultTeammateCrypto.slotID(salt: header.salt, deviceID: $0.deviceID) })
        #expect(Set(slots.map(\.slotID)) == expected)
        let readable = teammates.file.prefix(Self.slotsRange(count).upperBound)
        for device in teammates.recipients + [teammates.sender] {
            #expect(readable.range(of: device.deviceID.bytes) == nil)
            #expect(readable.range(of: device.agreementPublicKey) == nil)
        }
    }

    @Test func aFileForOtherTeammatesIsNotForThisMac() throws {
        let teammates = try Self.teammatesFile()
        #expect(throws: ShareError.notARecipient) {
            _ = try Self.open(teammates.file, as: TeamDeviceKeys.generate(), teammates: teammates.senderKeys)
        }
    }

    @Test func aSenderWhoIsNotATeammateIsRefused() throws {
        let teammates = try Self.teammatesFile()
        let stranger = ShareTeammateKeyModel(device: TeamDeviceKeys.generate())
        for keys in [[], [stranger]] {
            #expect(throws: ShareError.senderNotTeammate) {
                _ = try Self.open(teammates.file, as: teammates.recipients[0], teammates: keys)
            }
        }
    }

    @Test(arguments: 0..<64)
    func flippingAnyTeammatesHeaderByteFails(_ offset: Int) throws {
        let teammates = try Self.teammatesFile()
        var file = teammates.file
        file[offset] ^= 0x01
        do {
            _ = try Self.open(file, as: teammates.recipients[0], teammates: teammates.senderKeys)
            Issue.record("a tampered header at \(offset) opened")
        } catch let error as ShareError {
            // A changed salt or recipient count moves this Mac's slot: indistinguishable from a
            // file for someone else until a key authenticates it.
            let saltOrCount = (FxVaultHeaderV2Model.Offset.salt..<FxVaultHeaderV2Model.Offset.nonce).contains(offset)
                || offset == FxVaultHeaderV2Model.Offset.recipientCount
            #expect(error == .invalidFile || (saltOrCount && error == .notARecipient), "offset \(offset): \(error)")
        }
    }

    @Test func flippingAnySlotByteFails() throws {
        let teammates = try Self.teammatesFile()
        let recipient = teammates.recipients[0]
        guard case .v2Teammates(let header, _) = try FxVaultFileV2Codec.inspect(teammates.file) else {
            Issue.record("expected a teammates file")
            return
        }
        let ownSlotID = FxVaultTeammateCrypto.slotID(salt: header.salt, deviceID: recipient.deviceID)
        let slots = try FxVaultRecipientSlot.parseAll(teammates.file, at: Limits.shareHeaderBytes, count: 2)
        let ownIndex = try #require(slots.firstIndex { $0.slotID == ownSlotID })
        let ownSlotIDBytes = (Limits.shareHeaderBytes + ownIndex * Limits.shareRecipientSlotBytes)
            ..< (Limits.shareHeaderBytes + ownIndex * Limits.shareRecipientSlotBytes + Limits.shareSlotIDBytes)
        for offset in Self.slotsRange(2) {
            var file = teammates.file
            file[offset] ^= 0x01
            do {
                _ = try Self.open(file, as: recipient, teammates: teammates.senderKeys)
                Issue.record("a tampered slot at \(offset) opened")
            } catch let error as ShareError {
                #expect(error == .invalidFile || (ownSlotIDBytes.contains(offset) && error == .notARecipient), "offset \(offset): \(error)")
            }
        }
    }

    @Test func flippingTeammatesCiphertextOrTagFails() throws {
        let teammates = try Self.teammatesFile()
        for offset in Self.slotsRange(2).upperBound..<teammates.file.count {
            var file = teammates.file
            file[offset] ^= 0x80
            #expect(throws: ShareError.invalidFile) {
                _ = try Self.open(file, as: teammates.recipients[0], teammates: teammates.senderKeys)
            }
        }
    }

    @Test func swappedOrDuplicatedSlotsAreRejected() throws {
        let teammates = try Self.teammatesFile()
        let range = Self.slotsRange(2)
        let first = teammates.file[range.lowerBound..<(range.lowerBound + Limits.shareRecipientSlotBytes)]
        let second = teammates.file[(range.lowerBound + Limits.shareRecipientSlotBytes)..<range.upperBound]
        var swapped = teammates.file
        swapped.replaceSubrange(range, with: second + first)
        var duplicated = teammates.file
        duplicated.replaceSubrange(range, with: first + first)
        for file in [swapped, duplicated] {
            #expect(throws: ShareError.invalidFile) { _ = try FxVaultFileV2Codec.inspect(file) }
            #expect(throws: ShareError.invalidFile) {
                _ = try Self.open(file, as: teammates.recipients[0], teammates: teammates.senderKeys)
            }
        }
    }

    /// (description, offset, replacement bytes) for a valid teammates-mode header.
    static let rejectedTeammatesHeaders: [(String, Int, [UInt8])] = [
        ("kdf id Argon2id", 12, [0x01]),
        ("aead id 0", 13, [0x00]),
        ("ops limit 3", 14, [0, 0, 0, 3]),
        ("memory set", 18, [0, 1, 0, 0]),
        ("parallelism 1", 22, [0x01]),
        ("flags 1", 23, [0x01]),
        ("no recipients", 53, [0x00]),
        ("eleven recipients", 53, [0x0B]),
        ("reserved byte", 60, [0x01]),
    ]

    @Test(arguments: 0..<rejectedTeammatesHeaders.count)
    func teammatesHeaderRulesAreChecked(_ index: Int) throws {
        let (_, offset, bytes) = Self.rejectedTeammatesHeaders[index]
        let teammates = try Self.teammatesFile()
        var file = teammates.file
        file.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        #expect(throws: ShareError.invalidFile) { _ = try FxVaultFileV2Codec.inspect(file) }
    }

    @Test func recipientCountMustMatchTheSlots() throws {
        let teammates = try Self.teammatesFile()
        for count: UInt8 in [1, 3] {
            var file = teammates.file
            file[FxVaultHeaderV2Model.Offset.recipientCount] = count
            #expect(throws: (any Error).self) {
                _ = try Self.open(file, as: teammates.recipients[0], teammates: teammates.senderKeys)
            }
        }
        // Three slots claimed, two present and too few bytes left for the third.
        let short = try Self.teammatesFile(recipientCount: 2, payload: Data("{}".utf8))
        var file = short.file
        file[FxVaultHeaderV2Model.Offset.recipientCount] = 3
        #expect(throws: ShareError.invalidFile) { _ = try FxVaultFileV2Codec.inspect(file) }
    }

    @Test func oversizedOrTruncatedTeammatesFilesAreRejected() throws {
        let teammates = try Self.teammatesFile()
        let minimum = Self.slotsRange(2).upperBound + Limits.shareSenderPrefixBytes + Limits.gcmTagBytes
        for file in [
            teammates.file + Data(count: Limits.maxShareFileV2Bytes),
            teammates.file.prefix(minimum - 1),
            teammates.file.prefix(Self.slotsRange(2).upperBound - 1),
        ] {
            #expect(throws: ShareError.invalidFile) { _ = try FxVaultFileV2Codec.inspect(file) }
        }
    }

    // MARK: - Signatures

    /// Seals like ``FxVaultFileV2Codec/sealForTeammates(payload:sender:recipients:)`` but with the
    /// prefix produced by `prefix`, so a valid ciphertext can carry a bad signature or sender.
    static func sealWithPrefix(
        recipients: [TeamDeviceKeys],
        prefix: (_ header: Data, _ slots: Data) throws -> Data
    ) throws -> Data {
        let header = try FxVaultHeaderV2Model.freshTeammates(recipientCount: recipients.count)
        let headerBytes = header.encoded()
        let contentKey = SymmetricKey(size: .bits256)
        let slots = try recipients
            .map { try FxVaultTeammateCrypto.wrap(contentKey: contentKey, header: headerBytes, salt: header.salt, for: ShareTeammateKeyModel(device: $0)) }
            .sorted { $0.slotID.lexicographicallyPrecedes($1.slotID) }
        let slotBytes = slots.map { $0.encoded() }.reduce(Data(), +)
        let plaintext = try prefix(headerBytes, slotBytes) + payload
        let box = try AES.GCM.seal(plaintext, using: contentKey, nonce: try AES.GCM.Nonce(data: header.nonce), authenticating: headerBytes + slotBytes)
        return headerBytes + slotBytes + box.ciphertext + box.tag
    }

    static func signedPrefix(header: Data, slots: Data, claimedSender: TeamDeviceKeys, signer: TeamDeviceKeys, announceKey: Data? = nil) throws -> Data {
        let announce = announceKey ?? claimedSender.announceKey
        let message = FxVaultTeammateCrypto.signedMessage(
            header: header,
            slots: slots,
            sender: claimedSender.deviceID,
            announceKey: announce,
            payloadDigest: Data(SHA256.hash(data: payload))
        )
        return claimedSender.deviceID.bytes + announce + (try signer.signing.signature(for: message))
    }

    @Test func aValidPrefixOpens() throws {
        let sender = TeamDeviceKeys.generate()
        let recipient = TeamDeviceKeys.generate()
        let file = try Self.sealWithPrefix(recipients: [recipient]) { header, slots in
            try Self.signedPrefix(header: header, slots: slots, claimedSender: sender, signer: sender)
        }
        #expect(try Self.open(file, as: recipient, teammates: [ShareTeammateKeyModel(device: sender)]) == Self.payload)
    }

    @Test(arguments: 0..<TeamProtocol.signatureBytes)
    func flippingASignatureByteFails(_ index: Int) throws {
        let sender = TeamDeviceKeys.generate()
        let recipient = TeamDeviceKeys.generate()
        let file = try Self.sealWithPrefix(recipients: [recipient]) { header, slots in
            var prefix = try Self.signedPrefix(header: header, slots: slots, claimedSender: sender, signer: sender)
            prefix[TeamProtocol.deviceIDBytes + TeamProtocol.announceKeyBytes + index] ^= 0x01
            return prefix
        }
        #expect(throws: ShareError.invalidFile) {
            _ = try Self.open(file, as: recipient, teammates: [ShareTeammateKeyModel(device: sender)])
        }
    }

    @Test func aTeammateCannotSignAsAnother() throws {
        let claimed = TeamDeviceKeys.generate()
        let signer = TeamDeviceKeys.generate()
        let recipient = TeamDeviceKeys.generate()
        let file = try Self.sealWithPrefix(recipients: [recipient]) { header, slots in
            try Self.signedPrefix(header: header, slots: slots, claimedSender: claimed, signer: signer)
        }
        #expect(throws: ShareError.invalidFile) {
            _ = try Self.open(file, as: recipient, teammates: [claimed, signer].map { ShareTeammateKeyModel(device: $0) })
        }
    }

    @Test func theSignatureCoversTheAnnounceKeyAndTheSlots() throws {
        let sender = TeamDeviceKeys.generate()
        let recipient = TeamDeviceKeys.generate()
        let other = TeamDeviceKeys.generate()
        let keys = [ShareTeammateKeyModel(device: sender)]
        // Signed over a different announce key than the one sent.
        let swappedAnnounce = try Self.sealWithPrefix(recipients: [recipient]) { header, slots in
            var prefix = try Self.signedPrefix(header: header, slots: slots, claimedSender: sender, signer: sender)
            prefix.replaceSubrange(TeamProtocol.deviceIDBytes..<(TeamProtocol.deviceIDBytes + TeamProtocol.announceKeyBytes), with: Data(count: TeamProtocol.announceKeyBytes))
            return prefix
        }
        // Signed over other slots (a recipient re-sealing for someone else).
        let otherSlots = try Self.sealWithPrefix(recipients: [recipient, other]) { header, _ in
            try Self.signedPrefix(header: header, slots: Data(), claimedSender: sender, signer: sender)
        }
        for file in [swappedAnnounce, otherSlots] {
            #expect(throws: ShareError.invalidFile) { _ = try Self.open(file, as: recipient, teammates: keys) }
        }
    }

    @Test func aFileShorterThanTheSenderPrefixFails() throws {
        let sender = TeamDeviceKeys.generate()
        let recipient = TeamDeviceKeys.generate()
        let header = try FxVaultHeaderV2Model.freshTeammates(recipientCount: 1)
        let headerBytes = header.encoded()
        let contentKey = SymmetricKey(size: .bits256)
        let slot = try FxVaultTeammateCrypto.wrap(contentKey: contentKey, header: headerBytes, salt: header.salt, for: ShareTeammateKeyModel(device: recipient))
        let aad = headerBytes + slot.encoded()
        // A correctly sealed plaintext one byte shorter than the sender prefix.
        let plaintext = Data(count: Limits.shareSenderPrefixBytes - 1)
        let box = try AES.GCM.seal(plaintext, using: contentKey, nonce: try AES.GCM.Nonce(data: header.nonce), authenticating: aad)
        let file = aad + box.ciphertext + box.tag
        #expect(throws: ShareError.invalidFile) { _ = try FxVaultFileV2Codec.inspect(file) }
        #expect(throws: ShareError.invalidFile) {
            _ = try Self.open(file, as: recipient, teammates: [ShareTeammateKeyModel(device: sender)])
        }
    }

    // MARK: - Sealing rules

    @Test func sealingNeedsOneToTenDistinctRecipients() throws {
        let codec = FxVaultFileV2Codec(deriver: FakeKeyDeriver())
        let sender = TeamDeviceKeys.generate()
        let one = ShareTeammateKeyModel(device: TeamDeviceKeys.generate())
        let eleven = (0...Limits.maxShareRecipients).map { _ in ShareTeammateKeyModel(device: TeamDeviceKeys.generate()) }
        for recipients in [[], eleven, [one, one]] {
            #expect(throws: ShareError.encryptionFailed) {
                _ = try codec.sealForTeammates(payload: SecretBytes(Self.payload), sender: sender, recipients: recipients)
            }
        }
        #expect(throws: ShareError.payloadTooLarge) {
            _ = try codec.sealForTeammates(payload: SecretBytes(count: Limits.maxSharePayloadBytes + 1), sender: sender, recipients: [one])
        }
    }

    @Test func everyTeammatesExportHasAFreshSaltNonceAndKey() throws {
        let first = try Self.teammatesFile(recipientCount: 1)
        let codec = FxVaultFileV2Codec(deriver: FakeKeyDeriver())
        let second = try codec.sealForTeammates(
            payload: SecretBytes(Self.payload),
            sender: first.sender,
            recipients: [ShareTeammateKeyModel(device: first.recipients[0])]
        )
        let saltAndNonce = FxVaultHeaderV2Model.Offset.salt..<FxVaultHeaderV2Model.Offset.mode
        #expect(first.file[saltAndNonce] != second[saltAndNonce])
        #expect(first.file.suffix(Limits.gcmTagBytes) != second.suffix(Limits.gcmTagBytes))
    }

    @Test func teammateKeysAreChecked() throws {
        let device = TeamDeviceKeys.generate()
        let keys = try ShareTeammateKeyModel(signingPublicKey: device.signingPublicKey, agreementPublicKey: device.agreementPublicKey)
        #expect(keys.deviceID == device.deviceID)
        #expect(keys == ShareTeammateKeyModel(device: device))
        #expect(throws: ShareError.teamCardInvalid) {
            _ = try ShareTeammateKeyModel(signingPublicKey: Data(count: 31), agreementPublicKey: device.agreementPublicKey)
        }
    }
}
