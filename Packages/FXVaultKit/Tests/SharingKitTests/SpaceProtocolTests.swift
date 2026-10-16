import CryptoKit
import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// `fxvault-space/v1` (v0.6.0, tasks/todo.md S1–S10): versions and their chain, epoch keys and
/// membership, the marker and the gate.
@Suite("Shared spaces")
struct SpaceProtocolTests {
    struct Device {
        let keys = TeamDeviceKeys.generate()
        let name: String

        var member: SpaceMemberModel {
            SpaceMemberModel(card: keys.card(login: name.lowercased(), displayName: name, macName: ""))
        }
    }

    static let date = Date(timeIntervalSince1970: 1_790_000_000)
    static let binding = SpaceBindingModel(githubRepoID: "R_repo-a", ownerLogin: "owner-a", repositoryName: "repo-a", environmentName: "production")

    static func snapshot(_ pairs: [(String, String)], reason: String = "") -> SpaceSnapshotModel {
        SpaceSnapshotModel(reason: reason, items: pairs.map {
            SpaceItemModel(kind: .secret, name: $0.0, value: SecretBytes(utf8: $0.1), githubUpdatedAt: date)
        })
    }

    static func values(_ snapshot: SpaceSnapshotModel) -> [String: String] {
        Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.name, $0.value?.utf8String() ?? "") })
    }

    /// Ana creates a space with Ben; returns the log and Ana's keychain.
    static func genesis(_ ana: Device, _ ben: Device, spaceID: SpaceID = SpaceID()) throws -> ([SpaceVersionModel], SpaceKeychain, SpaceStateModel) {
        let (version, keychain) = try SpaceVersionBuilder.genesis(
            spaceID: spaceID,
            binding: binding,
            members: [ana.member, ben.member],
            snapshot: snapshot([("API_KEY", "v1")], reason: "shared"),
            author: ana.keys,
            at: date
        )
        let state = try SpaceLog.verify([version], spaceID: spaceID)
        return ([version], keychain, state)
    }

    // MARK: - Versions and chain (S3)

    @Test func genesisAndPublishesFormAVerifiedChain() throws {
        let ana = Device(name: "Ana")
        let ben = Device(name: "Ben")
        var (log, keychain, state) = try Self.genesis(ana, ben)
        #expect(state.headVersion == 1 && state.epoch == 1)
        #expect(state.binding == Self.binding)
        #expect(state.members.map(\.name) == ["Ana", "Ben"])

        let second = try SpaceVersionBuilder.publish(state: state, keychain: keychain, snapshot: Self.snapshot([("API_KEY", "v2"), ("DB_URL", "x")]), author: ben.keys, at: Self.date)
        state = try SpaceLog.apply(second, to: state)
        log.append(second)
        #expect(state.headVersion == 2)
        #expect(state.headHash == second.hash)
        #expect(try SpaceLog.verify(log, spaceID: state.spaceID) == state)

        // Ben opens everything with his own wraps.
        let bens = try SpaceKeychain(versions: log, device: ben.keys)
        let opened = try SpaceVersionBuilder.snapshot(of: second, keychain: bens)
        #expect(Self.values(opened) == ["API_KEY": "v2", "DB_URL": "x"])
        #expect(try SpaceVersionBuilder.snapshot(of: log[0], keychain: bens).reason == "shared")
        _ = keychain
    }

    @Test func versionsRoundTripThroughTheirBytes() throws {
        let ana = Device(name: "Ana")
        let ben = Device(name: "Ben")
        let (log, keychain, _) = try Self.genesis(ana, ben)
        let decoded = try SpaceVersionModel.decode(log[0].encoded())
        #expect(decoded == log[0])
        #expect(decoded.hash == log[0].hash)
        #expect(Self.values(try SpaceVersionBuilder.snapshot(of: decoded, keychain: keychain)) == ["API_KEY": "v1"])
        #expect(throws: ShareError.spaceVersionInvalid) { try SpaceVersionModel.decode(Data([1, 2, 3])) }
    }

    @Test func tamperingGapsForeignAuthorsAndOtherSpacesAreRefused() throws {
        let ana = Device(name: "Ana")
        let ben = Device(name: "Ben")
        let eve = Device(name: "Eve")
        let (log, keychain, state) = try Self.genesis(ana, ben)
        let next = try SpaceVersionBuilder.publish(state: state, keychain: keychain, snapshot: Self.snapshot([("API_KEY", "v2")]), author: ana.keys, at: Self.date)

        var bytes = next.encoded()
        bytes[bytes.count - 70] ^= 0x01
        let flipped = try SpaceVersionModel.decode(bytes)
        #expect(throws: SpaceLogFailure.badSignature) { try SpaceLog.apply(flipped, to: state) }

        let third = try SpaceVersionBuilder.publish(state: try SpaceLog.apply(next, to: state), keychain: keychain, snapshot: Self.snapshot([]), author: ana.keys, at: Self.date)
        #expect(throws: SpaceLogFailure.numberGap) { try SpaceLog.apply(third, to: state) }

        var eveState = state
        eveState = SpaceStateModel(spaceID: state.spaceID, binding: state.binding, members: state.members + [eve.member], epoch: 1, headVersion: 1, headHash: state.headHash)
        let forged = try SpaceVersionBuilder.publish(state: eveState, keychain: keychain, snapshot: Self.snapshot([]), author: eve.keys, at: Self.date)
        #expect(throws: SpaceLogFailure.unknownAuthor) { try SpaceLog.apply(forged, to: state) }

        let (other, _, _) = try Self.genesis(ana, ben)
        #expect(throws: SpaceLogFailure.wrongSpace) { try SpaceLog.verify(other, spaceID: state.spaceID) }
        #expect(throws: SpaceLogFailure.notGenesis) { try SpaceLog.verify([next], spaceID: state.spaceID) }
        _ = log
    }

    @Test func twoPublishesOnTheSameHeadCannotBothJoinTheChain() throws {
        let ana = Device(name: "Ana")
        let ben = Device(name: "Ben")
        let (_, keychain, state) = try Self.genesis(ana, ben)
        let fromAna = try SpaceVersionBuilder.publish(state: state, keychain: keychain, snapshot: Self.snapshot([("API_KEY", "ana")]), author: ana.keys, at: Self.date)
        let fromBen = try SpaceVersionBuilder.publish(state: state, keychain: keychain, snapshot: Self.snapshot([("API_KEY", "ben")]), author: ben.keys, at: Self.date)
        let afterAna = try SpaceLog.apply(fromAna, to: state)
        #expect(fromAna.hash != fromBen.hash)
        #expect(throws: SpaceLogFailure.numberGap) { try SpaceLog.apply(fromBen, to: afterAna) }
    }

    // MARK: - Members and epochs (S7, Q2)

    @Test func addingAMemberHandsOverTheWholeHistory() throws {
        let ana = Device(name: "Ana")
        let ben = Device(name: "Ben")
        let cleo = Device(name: "Cleo")
        var (log, keychain, state) = try Self.genesis(ana, ben)
        let published = try SpaceVersionBuilder.publish(state: state, keychain: keychain, snapshot: Self.snapshot([("API_KEY", "v2")]), author: ana.keys, at: Self.date)
        state = try SpaceLog.apply(published, to: state)
        log.append(published)

        let (added, after) = try SpaceVersionBuilder.members(state.members + [cleo.member], state: state, keychain: keychain, reason: "Cleo joins", author: ben.keys, at: Self.date)
        state = try SpaceLog.apply(added, to: state)
        log.append(added)
        #expect(state.epoch == 1)
        #expect(state.members.map(\.name) == ["Ana", "Ben", "Cleo"])
        #expect(after.epochs == [1])

        let cleos = try SpaceKeychain(versions: log, device: cleo.keys)
        #expect(Self.values(try SpaceVersionBuilder.snapshot(of: log[0], keychain: cleos)) == ["API_KEY": "v1"])
        #expect(Self.values(try SpaceVersionBuilder.snapshot(of: published, keychain: cleos)) == ["API_KEY": "v2"])
    }

    @Test func removingAMemberStartsANewEpochTheyCannotOpen() throws {
        let ana = Device(name: "Ana")
        let ben = Device(name: "Ben")
        var (log, keychain, state) = try Self.genesis(ana, ben)
        let (removed, after) = try SpaceVersionBuilder.members([ana.member], state: state, keychain: keychain, reason: "Ben left", author: ana.keys, at: Self.date)
        state = try SpaceLog.apply(removed, to: state)
        log.append(removed)
        #expect(state.epoch == 2)
        #expect(after.epochs == [1, 2])

        let secret = try SpaceVersionBuilder.publish(state: state, keychain: after, snapshot: Self.snapshot([("API_KEY", "rotated")]), author: ana.keys, at: Self.date)
        state = try SpaceLog.apply(secret, to: state)
        log.append(secret)

        let bens = try SpaceKeychain(versions: log, device: ben.keys)
        #expect(bens.epochs == [1], "Ben keeps what he saw, nothing after")
        #expect(throws: SpaceLogFailure.badKeyring) { try SpaceVersionBuilder.snapshot(of: secret, keychain: bens) }
        #expect(throws: SpaceLogFailure.unknownAuthor) {
            try SpaceVersionBuilder.publish(state: state, keychain: bens, snapshot: Self.snapshot([]), author: ben.keys, at: Self.date)
        }
        let anas = try SpaceKeychain(versions: log, device: ana.keys)
        #expect(Self.values(try SpaceVersionBuilder.snapshot(of: secret, keychain: anas)) == ["API_KEY": "rotated"])
        _ = keychain
    }

    @Test func aKeyringThatSkipsSomeoneIsRefused() throws {
        let ana = Device(name: "Ana")
        let ben = Device(name: "Ben")
        let cleo = Device(name: "Cleo")
        let (_, keychain, state) = try Self.genesis(ana, ben)
        // Cleo joins but gets no wrap: other members could never let her read.
        let header = SpaceVersionHeaderModel(
            spaceID: state.spaceID, version: 2, parentHash: state.headHash, epoch: 1, kind: .members,
            author: ana.keys.deviceID, createdAt: Self.date
        )
        let keyring = SpaceKeyringModel(binding: nil, members: state.members + [cleo.member], wraps: [])
        let headerBytes = header.encoded()
        let keyringBytes = keyring.encoded()
        let payload = try SpaceCrypto.sealPayload(
            SpaceSnapshotCodec.encode(SpaceSnapshotModel(reason: "", items: [])),
            epochKey: try #require(keychain.key(1)), spaceID: state.spaceID, header: headerBytes, keyring: keyringBytes
        )
        let hash = SpaceVersionModel.hash(header: headerBytes, keyring: keyringBytes, payload: payload)
        let version = SpaceVersionModel(
            header: header, keyring: keyring, headerBytes: headerBytes, keyringBytes: keyringBytes,
            payloadCiphertext: payload, signature: try ana.keys.sign(SpaceVersionModel.signedMessage(hash: hash))
        )
        #expect(throws: SpaceLogFailure.badKeyring) { try SpaceLog.apply(version, to: state) }
    }

    @Test func fingerprintsMatchAcrossMembersAndDifferByValue() throws {
        let ana = Device(name: "Ana")
        let ben = Device(name: "Ben")
        let (log, keychain, state) = try Self.genesis(ana, ben)
        let bens = try SpaceKeychain(versions: log, device: ben.keys)
        let item = SpaceItemModel(kind: .secret, name: "API_KEY", value: SecretBytes(utf8: "v1"), githubUpdatedAt: nil)
        let other = SpaceItemModel(kind: .secret, name: "API_KEY", value: SecretBytes(utf8: "v2"), githubUpdatedAt: nil)
        let anaPrint = try #require(SpaceVersionBuilder.fingerprint(item, spaceID: state.spaceID, keychain: keychain))
        #expect(anaPrint.count == 8)
        #expect(SpaceVersionBuilder.fingerprint(item, spaceID: state.spaceID, keychain: bens) == anaPrint)
        #expect(SpaceVersionBuilder.fingerprint(other, spaceID: state.spaceID, keychain: bens) != anaPrint)
    }

    // MARK: - Marker and gate (S4, S5)

    @Test func markersAreSignedAndBounded() throws {
        let ana = Device(name: "Ana")
        let ben = Device(name: "Ben")
        let (_, _, state) = try Self.genesis(ana, ben)
        let marker = try SpaceMarkerModel.make(spaceID: state.spaceID, version: 1, state: .published, head: state.headHash, login: "ana", author: ana.keys, at: Self.date)
        let text = marker.encoded()
        #expect(text.utf8.count <= SpaceProtocol.maxMarkerBytes)
        #expect(text.hasPrefix("{\"at\":"))
        let decoded = try #require(SpaceMarkerModel.decode(text))
        #expect(decoded == marker)
        #expect(decoded.isSigned(by: state.members))
        let forged = text.replacingOccurrences(of: "\"v\":1", with: "\"v\":2")
        #expect(SpaceMarkerModel.decode(forged)?.isSigned(by: state.members) == false)
        #expect(SpaceMarkerModel.decode("not json") == nil)
        #expect(SpaceMarkerModel.decode(String(repeating: " ", count: 600) + text) == nil)
    }

    @Test(arguments: GateCase.allCases)
    func theGateDecides(_ gate: GateCase) throws {
        let ana = Device(name: "Ana")
        let ben = Device(name: "Ben")
        let eve = Device(name: "Eve")
        let (_, _, state) = try Self.genesis(ana, ben)
        let other = Data(repeating: 7, count: 32)
        let now = Self.date
        func marker(_ version: UInt64, _ markerState: SpaceMarkerModel.State, _ head: Data, by device: Device = ben, at date: Date = Self.date) throws -> String {
            try SpaceMarkerModel.make(spaceID: state.spaceID, version: version, state: markerState, head: head, login: device.name.lowercased(), author: device.keys, at: date).encoded()
        }
        let (text, expected): (String?, SpaceGateDecision) = switch gate {
        case .none: (nil, .clear)
        case .published: (try marker(1, .published, state.headHash), .clear)
        case .forked: (try marker(1, .published, other), .forked)
        case .behind: (try marker(3, .published, other), .behind(version: 3, login: "ben"))
        case .ahead: (try marker(0, .published, other), .ahead)
        case .publishingNow: (try marker(2, .publishing, state.headHash), .publishing(login: "ben", since: now, isStale: false))
        case .publishingStale: (try marker(2, .publishing, state.headHash, at: now.addingTimeInterval(-16 * 60)), .publishing(login: "ben", since: now.addingTimeInterval(-16 * 60), isStale: true))
        case .ownClaim: (try marker(2, .publishing, state.headHash, by: ana), .clear)
        case .publishingAhead: (try marker(4, .publishing, other), .behind(version: 3, login: "ben"))
        case .stranger: (try marker(1, .published, state.headHash, by: eve), .invalidMarker)
        case .garbage: ("{}", .invalidMarker)
        }
        #expect(SpaceGate.decide(markerText: text, state: state, device: ana.keys.deviceID, now: now) == expected)
    }

    enum GateCase: CaseIterable {
        case none, published, forked, behind, ahead, publishingNow, publishingStale, ownClaim, publishingAhead, stranger, garbage
    }
}
