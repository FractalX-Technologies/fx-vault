import CryptoKit
import Foundation
import VaultCore

/// A teammate's public keys as a teammates-mode `.fxvault` file needs them (v0.9.0): the X25519
/// agreement key a content key is wrapped for, and the Ed25519 signing key a sender's signature is
/// checked with. The device id is derived from the keys, so it cannot be claimed.
///
/// Lighter than ``TeamCardModel``: a teammate paired remotely is stored without an announce key
/// until one arrives, and a file needs none.
public struct ShareTeammateKeyModel: Sendable, Hashable {
    public let deviceID: TeamDeviceID
    public let signingPublicKey: Data
    public let agreementPublicKey: Data

    /// Checks both keys and derives the device id. Throws `teamCardInvalid` for a key that does
    /// not parse.
    public init(signingPublicKey: Data, agreementPublicKey: Data) throws(ShareError) {
        guard signingPublicKey.count == TeamProtocol.keyBytes,
              agreementPublicKey.count == TeamProtocol.keyBytes,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey)) != nil,
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreementPublicKey)) != nil
        else { throw .teamCardInvalid }
        deviceID = TeamDeviceID.derive(signingPublicKey: signingPublicKey, agreementPublicKey: agreementPublicKey)
        self.signingPublicKey = Data(signingPublicKey)
        self.agreementPublicKey = Data(agreementPublicKey)
    }

    /// The keys of a verified card.
    public init(card: TeamCardModel) {
        deviceID = card.deviceID
        signingPublicKey = card.signingPublicKey
        agreementPublicKey = card.agreementPublicKey
    }

    /// The keys of this Mac's own device (tests, and a sender that seals a copy for itself).
    public init(device: TeamDeviceKeys) {
        deviceID = device.deviceID
        signingPublicKey = device.signingPublicKey
        agreementPublicKey = device.agreementPublicKey
    }

    func isValidSignature(_ signature: Data, for message: Data) -> Bool {
        guard signature.count == TeamProtocol.signatureBytes,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey)
        else { return false }
        return key.isValidSignature(signature, for: message)
    }
}

/// What a teammates-mode file yields to one of its recipients (v0.9.0).
public struct FxVaultTeammateFileModel: Sendable {
    /// The payload JSON. The caller wipes it.
    public let payload: SecretBytes
    /// The teammate who sealed and signed the file (verified).
    public let sender: TeamDeviceID
    /// The sender's current announce key, for a teammate paired remotely who has none yet.
    public let senderAnnounceKey: Data
}

/// What ``FxVaultFileV2Codec/inspect(_:)`` learns from a file without any key material.
public enum FxVaultFileInfo: Sendable, Hashable {
    /// A v1 file (always a passphrase).
    case v1(FxVaultHeaderModel)
    /// A format 2 file sealed under a passphrase.
    case v2Passphrase(FxVaultHeaderV2Model)
    /// A format 2 file sealed for `recipientCount` teammates.
    case v2Teammates(FxVaultHeaderV2Model, recipientCount: Int)

    /// True when opening the file needs the six-word passphrase.
    public var needsPassphrase: Bool {
        switch self {
        case .v1, .v2Passphrase: true
        case .v2Teammates: false
        }
    }
}

/// One recipient slot of a teammates file: `slotID(8) ‖ enc(32) ‖ wrappedKey(48)`, where
/// `wrappedKey` is the HPKE seal of the 32-byte content key for that teammate's agreement key.
struct FxVaultRecipientSlot: Sendable, Hashable {
    static let encapsulatedKeyBytes = TeamProtocol.keyBytes
    static let wrappedKeyBytes = Limits.dekBytes + Limits.gcmTagBytes

    let slotID: Data
    let encapsulatedKey: Data
    let wrappedKey: Data

    func encoded() -> Data {
        slotID + encapsulatedKey + wrappedKey
    }

    /// Reads `count` slots from `bytes` at `offset`. They must be in strictly ascending slot-id
    /// order (so never duplicated).
    static func parseAll(_ bytes: Data, at offset: Int, count: Int) throws(ShareError) -> [FxVaultRecipientSlot] {
        var slots: [FxVaultRecipientSlot] = []
        for index in 0..<count {
            let start = offset + index * Limits.shareRecipientSlotBytes
            guard let slotID = bytes.bytes(at: start, length: Limits.shareSlotIDBytes),
                  let encapsulatedKey = bytes.bytes(at: start + Limits.shareSlotIDBytes, length: encapsulatedKeyBytes),
                  let wrappedKey = bytes.bytes(
                      at: start + Limits.shareSlotIDBytes + encapsulatedKeyBytes,
                      length: wrappedKeyBytes
                  )
            else { throw .invalidFile }
            if let previous = slots.last, !previous.slotID.lexicographicallyPrecedes(slotID) {
                throw .invalidFile
            }
            slots.append(FxVaultRecipientSlot(slotID: slotID, encapsulatedKey: encapsulatedKey, wrappedKey: wrappedKey))
        }
        return slots
    }
}

/// The labels and keyed functions of teammates mode (SHARING-PROTOCOL.md §2.1).
enum FxVaultTeammateCrypto {
    static let slotLabel = Data("fxvault/file/v2/slot".utf8)
    static let wrapLabel = Data("fxvault/file/v2/wrap".utf8)
    static let signLabel = Data("fxvault/file/v2/sign".utf8)
    /// The HPKE suite of content-key wraps (the shared-spaces suite).
    static let wrapSuite = SpaceProtocol.wrapSuite

    /// `HMAC-SHA256(key: salt, LP(slot label) ‖ deviceID)[0..<8]`.
    static func slotID(salt: [UInt8], deviceID: TeamDeviceID) -> Data {
        var message = Data()
        message.appendLengthPrefixed(slotLabel)
        message.append(deviceID.bytes)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: salt))
        return Data(Data(mac).prefix(Limits.shareSlotIDBytes))
    }

    /// `LP(wrap label) ‖ header`.
    static func wrapInfo(header: Data) -> Data {
        var info = Data()
        info.appendLengthPrefixed(wrapLabel)
        info.append(header)
        return info
    }

    /// `LP(sign label) ‖ LP(header) ‖ LP(slots) ‖ LP(senderDeviceID) ‖ LP(senderAnnounceKey) ‖
    /// LP(SHA256(payload))`.
    static func signedMessage(header: Data, slots: Data, sender: TeamDeviceID, announceKey: Data, payloadDigest: Data) -> Data {
        var message = Data()
        message.appendLengthPrefixed(signLabel)
        message.appendLengthPrefixed(header)
        message.appendLengthPrefixed(slots)
        message.appendLengthPrefixed(sender.bytes)
        message.appendLengthPrefixed(announceKey)
        message.appendLengthPrefixed(payloadDigest)
        return message
    }

    static func wrap(contentKey: SymmetricKey, header: Data, salt: [UInt8], for recipient: ShareTeammateKeyModel) throws(ShareError) -> FxVaultRecipientSlot {
        do {
            let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient.agreementPublicKey)
            var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: wrapSuite, info: wrapInfo(header: header))
            let wrapped = try contentKey.withUnsafeBytes { try sender.seal($0) }
            let slot = FxVaultRecipientSlot(
                slotID: slotID(salt: salt, deviceID: recipient.deviceID),
                encapsulatedKey: sender.encapsulatedKey,
                wrappedKey: wrapped
            )
            guard slot.encapsulatedKey.count == FxVaultRecipientSlot.encapsulatedKeyBytes,
                  slot.wrappedKey.count == FxVaultRecipientSlot.wrappedKeyBytes
            else { throw ShareError.encryptionFailed }
            return slot
        } catch {
            throw .encryptionFailed
        }
    }

    /// Opens a slot with this device's agreement key; nil when it does not authenticate.
    static func unwrap(_ slot: FxVaultRecipientSlot, header: Data, agreement: Curve25519.KeyAgreement.PrivateKey) -> SymmetricKey? {
        guard var recipient = try? HPKE.Recipient(
            privateKey: agreement,
            ciphersuite: wrapSuite,
            info: wrapInfo(header: header),
            encapsulatedKey: slot.encapsulatedKey
        ), var bytes = try? recipient.open(slot.wrappedKey) else { return nil }
        defer { bytes.wipe() }
        guard bytes.count == Limits.dekBytes else { return nil }
        return SymmetricKey(data: bytes)
    }
}
