import CryptoKit
import Foundation
import VaultCore

/// Makes signed versions (S3, S7) with this device's keys.
public enum SpaceVersionBuilder {
    /// Version 1: binds the space to a scope, names the first members (this device included)
    /// and records the scope as shared. Returns the version and the epoch-1 key.
    public static func genesis(
        spaceID: SpaceID,
        binding: SpaceBindingModel,
        members: [SpaceMemberModel],
        snapshot: SpaceSnapshotModel,
        author: TeamDeviceKeys,
        at date: Date
    ) throws(SpaceLogFailure) -> (SpaceVersionModel, SpaceKeychain) {
        guard members.contains(where: { $0.deviceID == author.deviceID }) else { throw .unknownAuthor }
        let key = SymmetricKey(size: .bits256)
        let wraps = try members.map { member throws(SpaceLogFailure) in
            try SpaceCrypto.wrap(key, epoch: 1, spaceID: spaceID, for: member)
        }
        let header = SpaceVersionHeaderModel(
            spaceID: spaceID,
            version: 1,
            parentHash: SpaceProtocol.rootHash,
            epoch: 1,
            kind: .genesis,
            author: author.deviceID,
            createdAt: date
        )
        let version = try sign(
            header: header,
            keyring: SpaceKeyringModel(binding: binding, members: members, wraps: wraps),
            payload: SpaceSnapshotCodec.encode(snapshot),
            key: key,
            author: author
        )
        var keychain = SpaceKeychain()
        keychain.set(key, epoch: 1)
        return (version, keychain)
    }

    /// A verified push: the scope as GitHub now holds it.
    public static func publish(
        state: SpaceStateModel,
        keychain: SpaceKeychain,
        snapshot: SpaceSnapshotModel,
        author: TeamDeviceKeys,
        at date: Date
    ) throws(SpaceLogFailure) -> SpaceVersionModel {
        guard state.isMember(author.deviceID) else { throw .unknownAuthor }
        guard let key = keychain.key(state.epoch) else { throw .badKeyring }
        let header = SpaceVersionHeaderModel(
            spaceID: state.spaceID,
            version: state.headVersion + 1,
            parentHash: state.headHash,
            epoch: state.epoch,
            kind: .publish,
            author: author.deviceID,
            createdAt: date
        )
        return try sign(header: header, keyring: .empty, payload: SpaceSnapshotCodec.encode(snapshot), key: key, author: author)
    }

    /// A new member list. Removing anyone starts a new epoch (a new key for everyone left);
    /// adding wraps every epoch key so far for the new members. Returns the version and the
    /// keychain after it.
    public static func members(
        _ next: [SpaceMemberModel],
        state: SpaceStateModel,
        keychain: SpaceKeychain,
        reason: String,
        author: TeamDeviceKeys,
        at date: Date
    ) throws(SpaceLogFailure) -> (SpaceVersionModel, SpaceKeychain) {
        guard state.isMember(author.deviceID), !next.isEmpty else { throw .badKeyring }
        let previous = Set(state.members.map(\.deviceID))
        let current = Set(next.map(\.deviceID))
        let removed = previous.subtracting(current)
        let added = next.filter { !previous.contains($0.deviceID) }
        var keychain = keychain
        var wraps: [SpaceKeyWrapModel] = []
        var epoch = state.epoch
        if !removed.isEmpty {
            epoch += 1
            let key = SymmetricKey(size: .bits256)
            keychain.set(key, epoch: epoch)
            for member in next {
                wraps.append(try SpaceCrypto.wrap(key, epoch: epoch, spaceID: state.spaceID, for: member))
            }
        }
        for member in added {
            for oldEpoch in 1...max(1, epoch) where removed.isEmpty || oldEpoch < epoch {
                guard let key = keychain.key(oldEpoch) else { throw .badKeyring }
                wraps.append(try SpaceCrypto.wrap(key, epoch: oldEpoch, spaceID: state.spaceID, for: member))
            }
        }
        guard let key = keychain.key(epoch) else { throw .badKeyring }
        let header = SpaceVersionHeaderModel(
            spaceID: state.spaceID,
            version: state.headVersion + 1,
            parentHash: state.headHash,
            epoch: epoch,
            kind: .members,
            author: author.deviceID,
            createdAt: date
        )
        let version = try sign(
            header: header,
            keyring: SpaceKeyringModel(binding: nil, members: next, wraps: wraps),
            payload: SpaceSnapshotCodec.encode(SpaceSnapshotModel(reason: reason, items: [])),
            key: key,
            author: author
        )
        return (version, keychain)
    }

    /// Opens a version's payload with the keychain.
    public static func snapshot(of version: SpaceVersionModel, keychain: SpaceKeychain) throws(SpaceLogFailure) -> SpaceSnapshotModel {
        guard let key = keychain.key(version.header.epoch) else { throw .badKeyring }
        var plaintext = try SpaceCrypto.openPayload(version, epochKey: key)
        defer { plaintext.wipe() }
        return try SpaceSnapshotCodec.decode(plaintext)
    }

    /// The short fingerprint of a value in this space (the same on every member's Mac).
    public static func fingerprint(_ item: SpaceItemModel, spaceID: SpaceID, keychain: SpaceKeychain) -> String? {
        guard let value = item.value, let key = keychain.key(1) else { return nil }
        return SpaceCrypto.fingerprint(kind: item.kind, name: item.name, value: value, firstEpochKey: key, spaceID: spaceID)
    }

    private static func sign(
        header: SpaceVersionHeaderModel,
        keyring: SpaceKeyringModel,
        payload: Data,
        key: SymmetricKey,
        author: TeamDeviceKeys
    ) throws(SpaceLogFailure) -> SpaceVersionModel {
        var payload = payload
        defer { payload.wipe() }
        let headerBytes = header.encoded()
        let keyringBytes = keyring.encoded()
        let ciphertext = try SpaceCrypto.sealPayload(payload, epochKey: key, spaceID: header.spaceID, header: headerBytes, keyring: keyringBytes)
        let hash = SpaceVersionModel.hash(header: headerBytes, keyring: keyringBytes, payload: ciphertext)
        let signature: Data
        do {
            signature = try author.sign(SpaceVersionModel.signedMessage(hash: hash))
        } catch {
            throw .badSignature
        }
        return SpaceVersionModel(
            header: header,
            keyring: keyring,
            headerBytes: headerBytes,
            keyringBytes: keyringBytes,
            payloadCiphertext: ciphertext,
            signature: signature
        )
    }
}

/// The payload's plaintext: `format ‖ LP(reason) ‖ u32 count ‖ items`, each item
/// `u8 kind ‖ LP(name) ‖ u8 hasValue ‖ [LP(value)] ‖ u8 hasDate ‖ [i64 unix ms]`.
enum SpaceSnapshotCodec {
    static func encode(_ snapshot: SpaceSnapshotModel) -> Data {
        var data = Data([SpaceProtocol.format])
        data.appendLengthPrefixed(Data(snapshot.reason.utf8))
        data.appendBigEndian(UInt32(snapshot.items.count))
        for item in snapshot.items.sorted(by: { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }) {
            data.append(item.kind == .secret ? 1 : 2)
            data.appendLengthPrefixed(Data(item.name.utf8))
            if let value = item.value {
                data.append(1)
                value.withUnsafeBytes { data.appendLengthPrefixed(Data($0)) }
            } else {
                data.append(0)
            }
            if let date = item.githubUpdatedAt {
                data.append(1)
                data.appendBigEndian(Int64((date.timeIntervalSince1970 * 1000).rounded()))
            } else {
                data.append(0)
            }
        }
        return data
    }

    static func decode(_ data: Data) throws(SpaceLogFailure) -> SpaceSnapshotModel {
        do {
            var reader = NearbyByteReader(data)
            defer { reader.wipe() }
            guard try reader.byte() == SpaceProtocol.format else { throw SpaceLogFailure.malformed }
            guard let reason = String(data: try lengthPrefixed(&reader), encoding: .utf8) else { throw SpaceLogFailure.malformed }
            var items: [SpaceItemModel] = []
            for _ in 0..<Int(try reader.uint32()) {
                let kind: ConfigKind = switch try reader.byte() {
                case 1: .secret
                case 2: .variable
                default: throw SpaceLogFailure.malformed
                }
                guard let name = String(data: try lengthPrefixed(&reader), encoding: .utf8) else { throw SpaceLogFailure.malformed }
                var value: SecretBytes?
                if try reader.byte() == 1 {
                    var bytes = try lengthPrefixed(&reader)
                    value = SecretBytes(wipingSource: &bytes)
                }
                var date: Date?
                if try reader.byte() == 1 {
                    date = Date(timeIntervalSince1970: TimeInterval(Int64(bitPattern: try reader.uint64())) / 1000)
                }
                items.append(SpaceItemModel(kind: kind, name: name, value: value, githubUpdatedAt: date))
            }
            try reader.requireEnd()
            return SpaceSnapshotModel(reason: ChatTextSanitizer.sanitize(reason), items: items)
        } catch {
            throw .malformed
        }
    }
}
