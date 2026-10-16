import CryptoKit
import Foundation
import VaultCore

/// Constants of `fxvault-space/v1` (v0.6.0, tasks/todo.md S1–S10): versions, keys, the marker.
/// Documented in docs/SHARING-PROTOCOL.md §11.
public enum SpaceProtocol {
    public static let name = "fxvault-space/v1"
    /// Format byte of headers, keyrings, payloads and the marker (`f`).
    public static let format: UInt8 = 1
    /// The GitHub variable each shared scope carries (S4). User items may not use this name.
    public static let markerVariableName = GitHubNameValidator.spaceMarkerName
    /// A `publishing` marker older than this may be taken over after a confirmation (Q3).
    public static let claimStaleAfter: Duration = .seconds(15 * 60)
    /// Largest marker value, in UTF-8 bytes.
    public static let maxMarkerBytes = 512

    static let labelPrefix = "fxvault/space/v1"
    static let versionLabel = Data("\(labelPrefix)/version".utf8)
    static let signatureLabel = Data("\(labelPrefix)/signature".utf8)
    static let payloadLabel = Data("\(labelPrefix)/payload".utf8)
    static let wrapLabel = Data("\(labelPrefix)/wrap".utf8)
    static let markerLabel = Data("\(labelPrefix)/marker".utf8)
    static let fingerprintLabel = Data("\(labelPrefix)/fingerprint".utf8)

    /// Bytes of a version hash (SHA-256).
    public static let hashBytes = 32
    /// Bytes of an epoch key.
    static let keyBytes = 32
    /// Bytes of a short fingerprint shown in the history (hex: twice as many characters).
    static let fingerprintBytes = 4
    /// The parent hash of version 1.
    static let rootHash = Data(count: hashBytes)
    /// The HPKE suite of key wraps.
    static let wrapSuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    /// Largest encoded version accepted from a peer (a scope's full snapshot).
    public static let maxVersionBytes = Limits.maxNearbyPayloadBytes
    /// Largest whole log of a new space fetched in one session (it is verified before storing).
    public static let maxLogBytes = 4 * Limits.maxNearbyPayloadBytes
    /// Most heads one SPACE_HEADS frame carries (`16 ‖ u64 ‖ 32` bytes each).
    public static let maxHeads = 512
}

/// What a space is about: one scope of one GitHub repository (S1). Fixed at genesis.
public struct SpaceBindingModel: Sendable, Hashable {
    /// GitHub's node id of the repository.
    public let githubRepoID: String
    public let ownerLogin: String
    public let repositoryName: String
    /// The environment's name on GitHub; nil for the repository level.
    public let environmentName: String?

    public init(githubRepoID: String, ownerLogin: String, repositoryName: String, environmentName: String?) {
        self.githubRepoID = githubRepoID
        self.ownerLogin = ownerLogin
        self.repositoryName = repositoryName
        self.environmentName = environmentName
    }
}

/// A member device of a space: a teammate card without its announce key.
public struct SpaceMemberModel: Sendable, Hashable, Identifiable {
    public let deviceID: TeamDeviceID
    public let signingPublicKey: Data
    public let agreementPublicKey: Data
    public let login: String
    public let displayName: String
    public let macName: String

    public init(card: TeamCardModel) {
        deviceID = card.deviceID
        signingPublicKey = card.signingPublicKey
        agreementPublicKey = card.agreementPublicKey
        login = card.login
        displayName = card.displayName
        macName = card.macName
    }

    init(
        deviceID: TeamDeviceID,
        signingPublicKey: Data,
        agreementPublicKey: Data,
        login: String,
        displayName: String,
        macName: String
    ) {
        self.deviceID = deviceID
        self.signingPublicKey = signingPublicKey
        self.agreementPublicKey = agreementPublicKey
        self.login = login
        self.displayName = displayName
        self.macName = macName
    }

    public var id: TeamDeviceID {
        deviceID
    }

    /// The name to show.
    public var name: String {
        [displayName, login, macName].first { !$0.isEmpty } ?? deviceID.hex
    }

    func isValidSignature(_ signature: Data, for message: Data) -> Bool {
        guard signature.count == TeamProtocol.signatureBytes,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey)
        else { return false }
        return key.isValidSignature(signature, for: message)
    }
}

/// One secret or variable in a version's snapshot (what GitHub holds after that publish).
public struct SpaceItemModel: Sendable {
    public let kind: ConfigKind
    public let name: String
    /// Nil only for a secret the publisher had no value for (never pushed by this space).
    public let value: SecretBytes?
    /// GitHub's `updatedAt` after the push (secrets; verification facts for receivers).
    public let githubUpdatedAt: Date?

    public init(kind: ConfigKind, name: String, value: SecretBytes?, githubUpdatedAt: Date?) {
        self.kind = kind
        self.name = name
        self.value = value
        self.githubUpdatedAt = githubUpdatedAt
    }
}

/// The decrypted payload of a version: a note and, for genesis and publish, the full scope.
public struct SpaceSnapshotModel: Sendable {
    /// "Why", as the author typed it (may be empty).
    public let reason: String
    public let items: [SpaceItemModel]

    public init(reason: String, items: [SpaceItemModel]) {
        self.reason = reason
        self.items = items
    }

    /// Wipes every value.
    public func wipe() {
        for item in items {
            item.value?.wipe()
        }
    }
}

/// What a version records.
public enum SpaceVersionKind: UInt8, Sendable, Hashable, CaseIterable {
    /// Version 1: the binding, the first members and the scope as it was shared.
    case genesis = 1
    /// A verified push: the scope as GitHub now holds it.
    case publish = 2
    /// Members added or removed (a removal starts a new epoch with a new key).
    case members = 3
}

/// A version's fixed-size header (signed and authenticated with its payload).
public struct SpaceVersionHeaderModel: Sendable, Hashable {
    public let spaceID: SpaceID
    public let version: UInt64
    public let parentHash: Data
    public let epoch: UInt32
    public let kind: SpaceVersionKind
    public let author: TeamDeviceID
    public let createdAt: Date

    /// `format ‖ spaceID(16) ‖ u64 version ‖ parentHash(32) ‖ u32 epoch ‖ u8 kind ‖ author(16) ‖
    /// i64 createdAt (unix milliseconds)`.
    func encoded() -> Data {
        var data = Data([SpaceProtocol.format])
        data.append(contentsOf: spaceID.bytes)
        data.appendBigEndian(version)
        data.append(parentHash)
        data.appendBigEndian(epoch)
        data.append(kind.rawValue)
        data.append(author.bytes)
        data.appendBigEndian(Int64((createdAt.timeIntervalSince1970 * 1000).rounded()))
        return data
    }

    static func decode(_ data: Data) throws(NearbyFailure) -> SpaceVersionHeaderModel {
        var reader = NearbyByteReader(data)
        guard try reader.byte() == SpaceProtocol.format else { throw NearbyFailure(.unsupportedVersion) }
        guard let spaceID = SpaceID(bytes: try reader.bytes(Identifier<SpaceTag>.byteCount)) else {
            throw NearbyFailure(.malformedFrame)
        }
        let version = try reader.uint64()
        let parent = try reader.bytes(SpaceProtocol.hashBytes)
        let epoch = try reader.uint32()
        guard let kind = SpaceVersionKind(rawValue: try reader.byte()),
              let author = TeamDeviceID(bytes: try reader.bytes(TeamProtocol.deviceIDBytes))
        else { throw NearbyFailure(.malformedFrame) }
        let millis = Int64(bitPattern: try reader.uint64())
        try reader.requireEnd()
        return SpaceVersionHeaderModel(
            spaceID: spaceID,
            version: version,
            parentHash: parent,
            epoch: epoch,
            kind: kind,
            author: author,
            createdAt: Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        )
    }
}

/// An epoch key wrapped for one member device with HPKE (RFC 9180, X25519, SHA-256,
/// ChaCha20-Poly1305): only that device's agreement key opens it.
public struct SpaceKeyWrapModel: Sendable, Hashable {
    public let deviceID: TeamDeviceID
    public let epoch: UInt32
    let encapsulatedKey: Data
    let ciphertext: Data
}

/// The plaintext key material of genesis and members versions: the binding (genesis), the full
/// member list after the version, and the epoch keys wrapped for the devices that need them.
public struct SpaceKeyringModel: Sendable, Hashable {
    public let binding: SpaceBindingModel?
    public let members: [SpaceMemberModel]
    public let wraps: [SpaceKeyWrapModel]

    static let empty = SpaceKeyringModel(binding: nil, members: [], wraps: [])

    var isEmpty: Bool {
        binding == nil && members.isEmpty && wraps.isEmpty
    }

    func encoded() -> Data {
        guard !isEmpty else { return Data() }
        var data = Data([SpaceProtocol.format])
        if let binding {
            data.append(1)
            for text in [binding.githubRepoID, binding.ownerLogin, binding.repositoryName] {
                data.appendLengthPrefixed(Data(text.utf8))
            }
            if let environment = binding.environmentName {
                data.append(1)
                data.appendLengthPrefixed(Data(environment.utf8))
            } else {
                data.append(0)
            }
        } else {
            data.append(0)
        }
        data.appendBigEndian(UInt16(members.count))
        for member in members {
            data.append(member.deviceID.bytes)
            data.append(member.signingPublicKey)
            data.append(member.agreementPublicKey)
            for text in [member.login, member.displayName, member.macName] {
                let bytes = Data(text.utf8)
                data.appendBigEndian(UInt16(bytes.count))
                data.append(bytes)
            }
        }
        data.appendBigEndian(UInt16(wraps.count))
        for wrap in wraps {
            data.append(wrap.deviceID.bytes)
            data.appendBigEndian(wrap.epoch)
            data.appendLengthPrefixed(wrap.encapsulatedKey)
            data.appendLengthPrefixed(wrap.ciphertext)
        }
        return data
    }

    static func decode(_ data: Data) throws(NearbyFailure) -> SpaceKeyringModel {
        guard !data.isEmpty else { return .empty }
        var reader = NearbyByteReader(data)
        guard try reader.byte() == SpaceProtocol.format else { throw NearbyFailure(.unsupportedVersion) }
        var binding: SpaceBindingModel?
        if try reader.byte() == 1 {
            let repoID = try text(&reader)
            let owner = try text(&reader)
            let name = try text(&reader)
            let environment = try reader.byte() == 1 ? try text(&reader) : nil
            binding = SpaceBindingModel(githubRepoID: repoID, ownerLogin: owner, repositoryName: name, environmentName: environment)
        }
        var members: [SpaceMemberModel] = []
        for _ in 0..<Int(try reader.uint16()) {
            guard let deviceID = TeamDeviceID(bytes: try reader.bytes(TeamProtocol.deviceIDBytes)) else {
                throw NearbyFailure(.malformedFrame)
            }
            let signing = try reader.bytes(TeamProtocol.keyBytes)
            let agreement = try reader.bytes(TeamProtocol.keyBytes)
            var texts: [String] = []
            for _ in 0..<3 {
                let length = Int(try reader.uint16())
                guard length <= TeamProtocol.maxCardStringBytes,
                      let text = String(data: try reader.bytes(length), encoding: .utf8)
                else { throw NearbyFailure(.malformedFrame) }
                texts.append(DisplayNameSanitizer.sanitize(text))
            }
            guard TeamDeviceID.derive(signingPublicKey: signing, agreementPublicKey: agreement) == deviceID else {
                throw NearbyFailure(.invalidKey)
            }
            members.append(SpaceMemberModel(
                deviceID: deviceID,
                signingPublicKey: signing,
                agreementPublicKey: agreement,
                login: texts[0],
                displayName: texts[1],
                macName: texts[2]
            ))
        }
        var wraps: [SpaceKeyWrapModel] = []
        for _ in 0..<Int(try reader.uint16()) {
            guard let deviceID = TeamDeviceID(bytes: try reader.bytes(TeamProtocol.deviceIDBytes)) else {
                throw NearbyFailure(.malformedFrame)
            }
            let epoch = try reader.uint32()
            let encapsulated = try lengthPrefixed(&reader)
            let ciphertext = try lengthPrefixed(&reader)
            wraps.append(SpaceKeyWrapModel(deviceID: deviceID, epoch: epoch, encapsulatedKey: encapsulated, ciphertext: ciphertext))
        }
        try reader.requireEnd()
        return SpaceKeyringModel(binding: binding, members: members, wraps: wraps)
    }

    private static func text(_ reader: inout NearbyByteReader) throws(NearbyFailure) -> String {
        guard let text = String(data: try lengthPrefixed(&reader), encoding: .utf8) else { throw NearbyFailure(.malformedFrame) }
        return text
    }
}

/// `u32 length ‖ bytes` (bounded by ``SpaceProtocol/maxVersionBytes``).
func lengthPrefixed(_ reader: inout NearbyByteReader) throws(NearbyFailure) -> Data {
    let length = Int(try reader.uint32())
    guard length <= SpaceProtocol.maxVersionBytes else { throw NearbyFailure(.oversizeFrame) }
    return try reader.bytes(length)
}

/// One signed version of a space log (S3).
///
/// Wire form: `u32 ‖ header ‖ u32 ‖ keyring ‖ u32 ‖ payload ciphertext ‖ signature(64)`;
/// `hash = SHA256(LP(version label) ‖ LP(header) ‖ LP(keyring) ‖ LP(payload))`; the author signs
/// `LP(signature label) ‖ LP(hash)`.
public struct SpaceVersionModel: Sendable, Hashable {
    public let header: SpaceVersionHeaderModel
    public let keyring: SpaceKeyringModel
    let headerBytes: Data
    let keyringBytes: Data
    let payloadCiphertext: Data
    let signature: Data

    /// The version's hash (its identity in the chain and in the marker).
    public var hash: Data {
        Self.hash(header: headerBytes, keyring: keyringBytes, payload: payloadCiphertext)
    }

    static func hash(header: Data, keyring: Data, payload: Data) -> Data {
        var message = Data()
        message.appendLengthPrefixed(SpaceProtocol.versionLabel)
        message.appendLengthPrefixed(header)
        message.appendLengthPrefixed(keyring)
        message.appendLengthPrefixed(payload)
        return Data(SHA256.hash(data: message))
    }

    static func signedMessage(hash: Data) -> Data {
        var message = Data()
        message.appendLengthPrefixed(SpaceProtocol.signatureLabel)
        message.appendLengthPrefixed(hash)
        return message
    }

    /// The bytes stored and sent between members.
    public func encoded() -> Data {
        var data = Data()
        data.appendLengthPrefixed(headerBytes)
        data.appendLengthPrefixed(keyringBytes)
        data.appendLengthPrefixed(payloadCiphertext)
        data.append(signature)
        return data
    }

    /// Reads a version (structure only; ``SpaceLog`` checks the chain and the signature).
    public static func decode(_ data: Data) throws(ShareError) -> SpaceVersionModel {
        do {
            guard data.count <= SpaceProtocol.maxVersionBytes else { throw NearbyFailure(.oversizeFrame) }
            var reader = NearbyByteReader(data)
            let headerBytes = try lengthPrefixed(&reader)
            let keyringBytes = try lengthPrefixed(&reader)
            let payload = try lengthPrefixed(&reader)
            let signature = try reader.bytes(TeamProtocol.signatureBytes)
            try reader.requireEnd()
            return SpaceVersionModel(
                header: try SpaceVersionHeaderModel.decode(headerBytes),
                keyring: try SpaceKeyringModel.decode(keyringBytes),
                headerBytes: headerBytes,
                keyringBytes: keyringBytes,
                payloadCiphertext: payload,
                signature: signature
            )
        } catch {
            throw .spaceVersionInvalid
        }
    }
}

/// A space's head as teammates exchange it (S6): which version each Mac holds.
public struct SpaceHeadModel: Sendable, Hashable {
    public let spaceID: SpaceID
    public let version: UInt64
    public let hash: Data

    public init(spaceID: SpaceID, version: UInt64, hash: Data) {
        self.spaceID = spaceID
        self.version = version
        self.hash = hash
    }
}
