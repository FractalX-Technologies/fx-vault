import CryptoKit
import Foundation
import VaultCore

/// Why a space log or version was refused. No names or values.
public enum SpaceLogFailure: Error, Sendable, Hashable {
    case malformed
    /// The first version is not a valid genesis.
    case notGenesis
    /// A version of another space.
    case wrongSpace
    /// A number that does not follow the head.
    case numberGap
    /// The parent hash is not the head's hash.
    case parentMismatch
    /// The author was not a member when it signed.
    case unknownAuthor
    case badSignature
    /// The epoch does not follow the membership rules.
    case epochMismatch
    /// A members version without a member, or a removal without a new key for everyone left.
    case badKeyring
}

/// The state a verified log leads to (S3, S7).
public struct SpaceStateModel: Sendable, Hashable {
    public let spaceID: SpaceID
    public let binding: SpaceBindingModel
    /// The members after the head.
    public let members: [SpaceMemberModel]
    /// The current epoch (its key encrypts new versions).
    public let epoch: UInt32
    public let headVersion: UInt64
    public let headHash: Data

    public func isMember(_ deviceID: TeamDeviceID) -> Bool {
        members.contains { $0.deviceID == deviceID }
    }

    func member(_ deviceID: TeamDeviceID) -> SpaceMemberModel? {
        members.first { $0.deviceID == deviceID }
    }
}

/// The verification rules of a space log (S3, S7). Pure; the store keeps verified versions only.
///
/// - Version 1 is genesis: parent = 32 zero bytes, epoch 1, a binding, its author among the
///   members, and an epoch-1 key wrapped for every member.
/// - Every later version has number head + 1 and parent = head's hash, and is signed by a device
///   that was a member before it.
/// - publish: the current epoch, no keyring.
/// - members: the full new member list. Removing anyone starts epoch + 1 with a new key wrapped
///   for every remaining member; only adding keeps the epoch and wraps every epoch key so far for
///   each new member (Q2: full history).
public enum SpaceLog {
    /// Verifies a whole log from genesis.
    public static func verify(_ versions: [SpaceVersionModel], spaceID: SpaceID) throws(SpaceLogFailure) -> SpaceStateModel {
        guard let genesis = versions.first else { throw .notGenesis }
        var state = try verifyGenesis(genesis, spaceID: spaceID)
        for version in versions.dropFirst() {
            state = try apply(version, to: state)
        }
        return state
    }

    /// Checks genesis and returns the state after it.
    public static func verifyGenesis(_ version: SpaceVersionModel, spaceID: SpaceID) throws(SpaceLogFailure) -> SpaceStateModel {
        let header = version.header
        guard header.spaceID == spaceID else { throw .wrongSpace }
        guard header.kind == .genesis, header.version == 1, header.parentHash == SpaceProtocol.rootHash,
              header.epoch == 1, let binding = version.keyring.binding
        else { throw .notGenesis }
        let members = version.keyring.members
        guard !members.isEmpty, Set(members.map(\.deviceID)).count == members.count else { throw .badKeyring }
        guard let author = members.first(where: { $0.deviceID == header.author }) else { throw .unknownAuthor }
        try checkSignature(version, by: author)
        try checkWraps(version.keyring.wraps, cover: members.map(\.deviceID), epochs: [1])
        return SpaceStateModel(
            spaceID: spaceID,
            binding: binding,
            members: members,
            epoch: 1,
            headVersion: 1,
            headHash: version.hash
        )
    }

    /// Checks `version` against `state` and returns the state after it.
    public static func apply(_ version: SpaceVersionModel, to state: SpaceStateModel) throws(SpaceLogFailure) -> SpaceStateModel {
        let header = version.header
        guard header.spaceID == state.spaceID else { throw .wrongSpace }
        guard header.version == state.headVersion + 1 else { throw .numberGap }
        guard header.parentHash == state.headHash else { throw .parentMismatch }
        guard let author = state.member(header.author) else { throw .unknownAuthor }
        try checkSignature(version, by: author)
        switch header.kind {
        case .genesis:
            throw .notGenesis
        case .publish:
            guard header.epoch == state.epoch, version.keyring.isEmpty else { throw .epochMismatch }
            return state.advanced(to: version, members: state.members, epoch: state.epoch)
        case .members:
            let keyring = version.keyring
            let next = keyring.members
            guard keyring.binding == nil, !next.isEmpty, Set(next.map(\.deviceID)).count == next.count else {
                throw .badKeyring
            }
            let previous = Set(state.members.map(\.deviceID))
            let current = Set(next.map(\.deviceID))
            let removed = previous.subtracting(current)
            let added = current.subtracting(previous)
            for member in next where previous.contains(member.deviceID) {
                // A member's keys never change inside a space.
                guard state.member(member.deviceID)?.signingPublicKey == member.signingPublicKey,
                      state.member(member.deviceID)?.agreementPublicKey == member.agreementPublicKey
                else { throw .badKeyring }
            }
            if removed.isEmpty {
                guard header.epoch == state.epoch else { throw .epochMismatch }
                try checkWraps(keyring.wraps, cover: Array(added), epochs: Array(1...state.epoch))
                return state.advanced(to: version, members: next, epoch: state.epoch)
            }
            guard header.epoch == state.epoch + 1 else { throw .epochMismatch }
            try checkWraps(keyring.wraps, cover: Array(current), epochs: [header.epoch])
            if !added.isEmpty {
                try checkWraps(keyring.wraps, cover: Array(added), epochs: Array(1...header.epoch))
            }
            return state.advanced(to: version, members: next, epoch: header.epoch)
        }
    }

    private static func checkSignature(_ version: SpaceVersionModel, by author: SpaceMemberModel) throws(SpaceLogFailure) {
        let message = SpaceVersionModel.signedMessage(hash: version.hash)
        guard author.isValidSignature(version.signature, for: message) else { throw .badSignature }
    }

    /// Every device in `cover` has a wrap for every epoch in `epochs`.
    private static func checkWraps(_ wraps: [SpaceKeyWrapModel], cover: [TeamDeviceID], epochs: [UInt32]) throws(SpaceLogFailure) {
        let present = Set(wraps.map { WrapKey(deviceID: $0.deviceID, epoch: $0.epoch) })
        for deviceID in cover {
            for epoch in epochs where !present.contains(WrapKey(deviceID: deviceID, epoch: epoch)) {
                throw .badKeyring
            }
        }
    }

    private struct WrapKey: Hashable {
        let deviceID: TeamDeviceID
        let epoch: UInt32
    }
}

extension SpaceStateModel {
    func advanced(to version: SpaceVersionModel, members: [SpaceMemberModel], epoch: UInt32) -> SpaceStateModel {
        SpaceStateModel(
            spaceID: spaceID,
            binding: binding,
            members: members,
            epoch: epoch,
            headVersion: version.header.version,
            headHash: version.hash
        )
    }
}

/// The epoch keys this device can open, from the wraps of a log (S7). Each key is one random
/// 32-byte AES key per epoch.
public struct SpaceKeychain: Sendable {
    private var keys: [UInt32: SymmetricKey] = [:]

    public init() {}

    /// Opens every wrap addressed to `device` in `versions`.
    public init(versions: [SpaceVersionModel], device: TeamDeviceKeys) throws(SpaceLogFailure) {
        for version in versions {
            try add(version, device: device)
        }
    }

    /// Opens the wraps of one more version.
    public mutating func add(_ version: SpaceVersionModel, device: TeamDeviceKeys) throws(SpaceLogFailure) {
        for wrap in version.keyring.wraps where wrap.deviceID == device.deviceID && keys[wrap.epoch] == nil {
            keys[wrap.epoch] = try SpaceCrypto.unwrap(wrap, spaceID: version.header.spaceID, agreement: device.agreement)
        }
    }

    public var epochs: [UInt32] {
        keys.keys.sorted()
    }

    func key(_ epoch: UInt32) -> SymmetricKey? {
        keys[epoch]
    }

    mutating func set(_ key: SymmetricKey, epoch: UInt32) {
        keys[epoch] = key
    }

    /// Exports one epoch key for the vault (sealed there). The caller wipes it.
    public func exportKey(_ epoch: UInt32) -> SecretBytes? {
        keys[epoch].map { key in key.withUnsafeBytes { SecretBytes(copying: $0) } }
    }

    /// Adds an epoch key read back from the vault.
    public mutating func importKey(_ bytes: SecretBytes, epoch: UInt32) {
        guard bytes.count == SpaceProtocol.keyBytes else { return }
        keys[epoch] = bytes.withUnsafeBytes { SymmetricKey(data: $0) }
    }
}

/// The cryptography of versions (S3, S7): payload sealing per epoch, HPKE key wraps, signatures
/// and short fingerprints.
enum SpaceCrypto {
    /// `HKDF-SHA256(epochKey, salt: spaceID, info: label)`.
    static func payloadKey(_ epochKey: SymmetricKey, spaceID: SpaceID) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: epochKey,
            salt: Data(spaceID.bytes),
            info: SpaceProtocol.payloadLabel,
            outputByteCount: SpaceProtocol.keyBytes
        )
    }

    /// The AAD of a payload: `SHA256(LP(header) ‖ LP(keyring))`.
    static func payloadAAD(header: Data, keyring: Data) -> Data {
        var message = Data()
        message.appendLengthPrefixed(header)
        message.appendLengthPrefixed(keyring)
        return Data(SHA256.hash(data: message))
    }

    static func sealPayload(
        _ plaintext: Data,
        epochKey: SymmetricKey,
        spaceID: SpaceID,
        header: Data,
        keyring: Data,
        nonce: AES.GCM.Nonce = AES.GCM.Nonce()
    ) throws(SpaceLogFailure) -> Data {
        do {
            let box = try AES.GCM.seal(
                plaintext,
                using: payloadKey(epochKey, spaceID: spaceID),
                nonce: nonce,
                authenticating: payloadAAD(header: header, keyring: keyring)
            )
            guard let combined = box.combined else { throw SpaceLogFailure.malformed }
            return combined
        } catch {
            throw .malformed
        }
    }

    static func openPayload(_ version: SpaceVersionModel, epochKey: SymmetricKey) throws(SpaceLogFailure) -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: version.payloadCiphertext)
            return try AES.GCM.open(
                box,
                using: payloadKey(epochKey, spaceID: version.header.spaceID),
                authenticating: payloadAAD(header: version.headerBytes, keyring: version.keyringBytes)
            )
        } catch {
            throw .malformed
        }
    }

    /// `LP(wrap label) ‖ spaceID ‖ u32 epoch ‖ deviceID`.
    static func wrapInfo(spaceID: SpaceID, epoch: UInt32, deviceID: TeamDeviceID) -> Data {
        var info = Data()
        info.appendLengthPrefixed(SpaceProtocol.wrapLabel)
        info.append(contentsOf: spaceID.bytes)
        info.appendBigEndian(epoch)
        info.append(deviceID.bytes)
        return info
    }

    static func wrap(
        _ key: SymmetricKey,
        epoch: UInt32,
        spaceID: SpaceID,
        for member: SpaceMemberModel
    ) throws(SpaceLogFailure) -> SpaceKeyWrapModel {
        do {
            let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: member.agreementPublicKey)
            var sender = try HPKE.Sender(
                recipientKey: recipient,
                ciphersuite: SpaceProtocol.wrapSuite,
                info: wrapInfo(spaceID: spaceID, epoch: epoch, deviceID: member.deviceID)
            )
            let ciphertext = try key.withUnsafeBytes { try sender.seal($0) }
            return SpaceKeyWrapModel(
                deviceID: member.deviceID,
                epoch: epoch,
                encapsulatedKey: sender.encapsulatedKey,
                ciphertext: ciphertext
            )
        } catch {
            throw .badKeyring
        }
    }

    static func unwrap(
        _ wrap: SpaceKeyWrapModel,
        spaceID: SpaceID,
        agreement: Curve25519.KeyAgreement.PrivateKey
    ) throws(SpaceLogFailure) -> SymmetricKey {
        do {
            var recipient = try HPKE.Recipient(
                privateKey: agreement,
                ciphersuite: SpaceProtocol.wrapSuite,
                info: wrapInfo(spaceID: spaceID, epoch: wrap.epoch, deviceID: wrap.deviceID),
                encapsulatedKey: wrap.encapsulatedKey
            )
            var bytes = try recipient.open(wrap.ciphertext)
            defer { bytes.wipe() }
            guard bytes.count == SpaceProtocol.keyBytes else { throw SpaceLogFailure.badKeyring }
            return SymmetricKey(data: bytes)
        } catch {
            throw .badKeyring
        }
    }

    /// A short hex fingerprint of a value, the same for every member: `HMAC(HKDF(epoch-1 key,
    /// salt: spaceID, info: label), u8 kind ‖ LP(name) ‖ LP(value))[0..<4]`.
    static func fingerprint(kind: ConfigKind, name: String, value: SecretBytes, firstEpochKey: SymmetricKey, spaceID: SpaceID) -> String {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: firstEpochKey,
            salt: Data(spaceID.bytes),
            info: SpaceProtocol.fingerprintLabel,
            outputByteCount: SpaceProtocol.keyBytes
        )
        var message = Data([kind == .secret ? 1 : 2])
        message.appendLengthPrefixed(Data(name.utf8))
        value.withUnsafeBytes { message.appendLengthPrefixed(Data($0)) }
        defer { message.wipe() }
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data(mac).prefix(SpaceProtocol.fingerprintBytes).hexEncoded
    }
}
