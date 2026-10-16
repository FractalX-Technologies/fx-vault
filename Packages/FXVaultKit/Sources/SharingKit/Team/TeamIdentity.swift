import CryptoKit
import Foundation
import VaultCore

/// A device's teammate id (16 bytes): derived from its two public keys, so a card cannot claim
/// another device's id (``TeamCardModel/decode(_:)`` checks it).
public struct TeamDeviceID: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let bytes: Data

    /// Wraps exactly ``TeamProtocol/deviceIDBytes`` bytes; nil for any other length.
    public init?(bytes: Data) {
        guard bytes.count == TeamProtocol.deviceIDBytes else { return nil }
        self.bytes = Data(bytes)
    }

    /// Lowercase hex, as stored in the database.
    public var hex: String {
        bytes.hexEncoded
    }

    /// Parses ``hex``.
    public init?(hex: String) {
        guard let data = Data(hexEncoded: hex) else { return nil }
        self.init(bytes: data)
    }

    public var description: String {
        hex
    }

    public static func < (lhs: TeamDeviceID, rhs: TeamDeviceID) -> Bool {
        lhs.hex < rhs.hex
    }

    /// `SHA256(LP(label) ‖ LP(signingPK) ‖ LP(agreementPK))[0..<16]`.
    static func derive(signingPublicKey: Data, agreementPublicKey: Data) -> TeamDeviceID {
        var message = Data()
        message.appendLengthPrefixed(TeamProtocol.deviceIDLabel)
        message.appendLengthPrefixed(signingPublicKey)
        message.appendLengthPrefixed(agreementPublicKey)
        let digest = Data(SHA256.hash(data: message)).prefix(TeamProtocol.deviceIDBytes)
        // The prefix of a 32-byte digest always has 16 bytes.
        return TeamDeviceID(unchecked: Data(digest))
    }

    private init(unchecked bytes: Data) {
        self.bytes = bytes
    }
}

/// What two Macs exchange when they pair (Add Teammate, T2): the public keys, the announce key
/// that seeds the device's pseudonyms, and names. The login and names are what the other person
/// typed or their Mac reports: unverified, sanitized, shown as they are.
///
/// Wire form (``encoded()``): `format(1) ‖ deviceID(16) ‖ signingPK(32) ‖ agreementPK(32) ‖
/// announceKey(32) ‖ u16 ‖ login ‖ u16 ‖ displayName ‖ u16 ‖ macName`.
public struct TeamCardModel: Sendable, Hashable {
    public let deviceID: TeamDeviceID
    /// Ed25519 public key (signs AUTH frames, pairing cards and, in v0.6.0, space versions).
    public let signingPublicKey: Data
    /// X25519 public key (v0.6.0: space keys are wrapped for it).
    public let agreementPublicKey: Data
    /// Seeds this device's pseudonyms. Known only to its teammates.
    public let announceKey: Data
    /// The GitHub login the person says is theirs (may be empty).
    public let login: String
    public let displayName: String
    public let macName: String

    /// A card for keys made here; the names are sanitized (≤ 63 bytes each).
    init(
        signingPublicKey: Data,
        agreementPublicKey: Data,
        announceKey: Data,
        login: String,
        displayName: String,
        macName: String
    ) {
        deviceID = TeamDeviceID.derive(signingPublicKey: signingPublicKey, agreementPublicKey: agreementPublicKey)
        self.signingPublicKey = signingPublicKey
        self.agreementPublicKey = agreementPublicKey
        self.announceKey = announceKey
        self.login = DisplayNameSanitizer.sanitize(login)
        self.displayName = DisplayNameSanitizer.sanitize(displayName)
        self.macName = DisplayNameSanitizer.sanitize(macName)
    }

    /// The card as stored (a teammate row read back): checks the keys and the id again.
    public init(
        deviceID: TeamDeviceID,
        signingPublicKey: Data,
        agreementPublicKey: Data,
        announceKey: Data,
        login: String,
        displayName: String,
        macName: String
    ) throws(ShareError) {
        let card = TeamCardModel(
            signingPublicKey: signingPublicKey,
            agreementPublicKey: agreementPublicKey,
            announceKey: announceKey,
            login: login,
            displayName: displayName,
            macName: macName
        )
        guard card.deviceID == deviceID, card.hasValidKeys else { throw .teamCardInvalid }
        self = card
    }

    /// The name to show: the display name, else the login, else the Mac name.
    public var name: String {
        [displayName, login, macName].first { !$0.isEmpty } ?? deviceID.hex
    }

    /// True when both public keys parse and the announce key has its size.
    var hasValidKeys: Bool {
        guard signingPublicKey.count == TeamProtocol.keyBytes,
              agreementPublicKey.count == TeamProtocol.keyBytes,
              announceKey.count == TeamProtocol.announceKeyBytes,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey)) != nil,
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreementPublicKey)) != nil
        else { return false }
        return true
    }

    /// Verifies an Ed25519 signature by this card's device.
    func isValidSignature(_ signature: Data, for message: Data) -> Bool {
        guard signature.count == TeamProtocol.signatureBytes,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey)
        else { return false }
        return key.isValidSignature(signature, for: message)
    }

    // MARK: - Wire form

    /// The card's bytes (see the type documentation).
    public func encoded() -> Data {
        var data = Data([TeamProtocol.version])
        data.append(deviceID.bytes)
        data.append(signingPublicKey)
        data.append(agreementPublicKey)
        data.append(announceKey)
        for text in [login, displayName, macName] {
            let bytes = Data(text.utf8)
            data.appendBigEndian(UInt16(bytes.count))
            data.append(bytes)
        }
        return data
    }

    /// Reads a card: format, sizes, UTF-8, the keys and the id derived from them. Names are
    /// sanitized again.
    static func decode(_ data: Data) throws(NearbyFailure) -> TeamCardModel {
        var reader = NearbyByteReader(data)
        guard try reader.byte() == TeamProtocol.version else { throw NearbyFailure(.unsupportedVersion) }
        guard let deviceID = TeamDeviceID(bytes: try reader.bytes(TeamProtocol.deviceIDBytes)) else {
            throw NearbyFailure(.malformedFrame)
        }
        let signingPublicKey = try reader.bytes(TeamProtocol.keyBytes)
        let agreementPublicKey = try reader.bytes(TeamProtocol.keyBytes)
        let announceKey = try reader.bytes(TeamProtocol.announceKeyBytes)
        var texts: [String] = []
        for _ in 0..<3 {
            let length = Int(try reader.uint16())
            guard length <= TeamProtocol.maxCardStringBytes,
                  let text = String(data: try reader.bytes(length), encoding: .utf8)
            else { throw NearbyFailure(.malformedFrame) }
            texts.append(text)
        }
        try reader.requireEnd()
        do {
            return try TeamCardModel(
                deviceID: deviceID,
                signingPublicKey: signingPublicKey,
                agreementPublicKey: agreementPublicKey,
                announceKey: announceKey,
                login: texts[0],
                displayName: texts[1],
                macName: texts[2]
            )
        } catch {
            throw NearbyFailure(.invalidKey)
        }
    }
}

/// This Mac's teammate keys (T1): an Ed25519 signing key, an X25519 agreement key and the
/// announce key. Created once per vault; VaultData keeps them encrypted in the vault and holds
/// them in memory only while it is unlocked.
public struct TeamDeviceKeys: Sendable {
    let signing: Curve25519.Signing.PrivateKey
    let agreement: Curve25519.KeyAgreement.PrivateKey
    /// Seeds this device's pseudonyms (``TeamPseudonym``).
    let announceKey: Data

    /// Bytes of ``secretBytes()``: signing seed, agreement key, announce key.
    public static let secretByteCount = 3 * TeamProtocol.keyBytes

    init(
        signing: Curve25519.Signing.PrivateKey,
        agreement: Curve25519.KeyAgreement.PrivateKey,
        announceKey: Data
    ) {
        self.signing = signing
        self.agreement = agreement
        self.announceKey = announceKey
    }

    /// New random keys (CryptoKit generation, `SystemRandomNumberGenerator`).
    public static func generate() -> TeamDeviceKeys {
        TeamDeviceKeys(
            signing: Curve25519.Signing.PrivateKey(),
            agreement: Curve25519.KeyAgreement.PrivateKey(),
            announceKey: Self.randomBytes(TeamProtocol.announceKeyBytes)
        )
    }

    /// Keys read back from the vault (``secretBytes()``).
    ///
    /// - Throws: `.teamKeysInvalid` for the wrong length or a key CryptoKit rejects.
    public init(secretBytes: SecretBytes) throws(ShareError) {
        guard secretBytes.count == Self.secretByteCount else { throw .teamKeysInvalid }
        let keys: TeamDeviceKeys? = secretBytes.withUnsafeBytes { raw in
            let bytes = Data(raw)
            let size = TeamProtocol.keyBytes
            guard let signing = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes.prefix(size)),
                  let agreement = try? Curve25519.KeyAgreement.PrivateKey(
                      rawRepresentation: bytes.dropFirst(size).prefix(size)
                  )
            else { return nil }
            return TeamDeviceKeys(signing: signing, agreement: agreement, announceKey: Data(bytes.suffix(size)))
        }
        guard let keys else { throw .teamKeysInvalid }
        self = keys
    }

    /// The three secrets for the vault: `signingSeed ‖ agreementKey ‖ announceKey` (96 bytes).
    /// The caller seals and wipes them.
    public func secretBytes() -> SecretBytes {
        var raw = signing.rawRepresentation
        raw.append(agreement.rawRepresentation)
        raw.append(announceKey)
        return SecretBytes(wipingSource: &raw)
    }

    /// A copy of these keys with a new announce key (after a teammate is removed: the old
    /// pseudonyms stop working for them).
    public func withNewAnnounceKey() -> TeamDeviceKeys {
        TeamDeviceKeys(signing: signing, agreement: agreement, announceKey: Self.randomBytes(TeamProtocol.announceKeyBytes))
    }

    public var signingPublicKey: Data {
        signing.publicKey.rawRepresentation
    }

    public var agreementPublicKey: Data {
        agreement.publicKey.rawRepresentation
    }

    public var deviceID: TeamDeviceID {
        TeamDeviceID.derive(signingPublicKey: signingPublicKey, agreementPublicKey: agreementPublicKey)
    }

    /// This device's card with the names it shows to a new teammate.
    public func card(login: String, displayName: String, macName: String) -> TeamCardModel {
        TeamCardModel(
            signingPublicKey: signingPublicKey,
            agreementPublicKey: agreementPublicKey,
            announceKey: announceKey,
            login: login,
            displayName: displayName,
            macName: macName
        )
    }

    /// An Ed25519 signature of `message`.
    func sign(_ message: Data) throws(NearbyFailure) -> Data {
        do {
            return try signing.signature(for: message)
        } catch {
            throw NearbyFailure(.invalidKey)
        }
    }

    private static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

/// What a chat needs to let teammates skip the code (chat version 3, T7): this device's keys,
/// its teammates and, when the chat was started from a teammate's bubble, that teammate.
public struct TeamChatIdentityModel: Sendable {
    let keys: TeamDeviceKeys
    let teammates: [TeamCardModel]
    let expectedPeer: TeamDeviceID?

    public init(keys: TeamDeviceKeys, teammates: [TeamCardModel], expectedPeer: TeamDeviceID? = nil) {
        self.keys = keys
        self.teammates = teammates
        self.expectedPeer = expectedPeer
    }
}
