import CryptoKit
import Foundation
import VaultCore

/// Where a session between two teammates is (T3, T6).
public enum TeamSessionPhase: String, Sendable, Hashable, CaseIterable {
    case idle
    /// I: HELLO sent. R: waiting for HELLO.
    case awaitingHello
    /// I: AUTH_I sent, waiting for AUTH_R. R: HELLO_R sent, waiting for AUTH_I.
    case authenticating
    /// Both proved they are the expected teammates: requests may flow.
    case ready
    /// I: a request (PING, CARD_UPDATE, SPACE_HEADS, SPACE_FETCH) sent, waiting for its answer.
    case awaitingAnswer
    /// R: a space request arrived; this Mac is reading its answer from the vault.
    case answering
    case finished
    case aborted

    public var isTerminal: Bool {
        self == .finished || self == .aborted
    }
}

/// Something a teammate session reports.
public enum TeamSessionEvent: Sendable, Equatable {
    /// The peer proved it is this teammate.
    case authenticated(TeamCardModel)
    /// R: the teammate pinged this Mac.
    case pinged(TeamCardModel)
    /// I: the ping arrived (PONG).
    case pingDelivered
    /// R: the teammate sent its card with a new announce key; store it.
    case cardUpdated(TeamCardModel)
    /// I: the card update was stored.
    case cardUpdateDelivered
    /// R (spaces service): the teammate's heads; answer with ``TeamSessionMachine/answerSpaceHeads(_:)``.
    case spaceHeadsRequested(TeamCardModel, [SpaceHeadModel])
    /// R (spaces service): the teammate asks for one version; answer with
    /// ``TeamSessionMachine/answerSpaceVersion(_:)``.
    case spaceVersionRequested(TeamCardModel, SpaceID, UInt64)
    /// I (spaces service): the teammate's heads.
    case spaceHeadsAnswered([SpaceHeadModel])
    /// I (spaces service): the version asked for, or nil when the teammate does not send it.
    case spaceVersionAnswered(Data?)
    case finished
    case aborted(NearbyAbortModel)
}

/// Frames to send and events after one input.
public struct TeamSessionStep: Sendable, Equatable {
    public var frames: [Data] = []
    public var events: [TeamSessionEvent] = []

    static let none = TeamSessionStep()
}

/// The paired handshake between teammates (T3) and the requests it carries: on the team service
/// PING and CARD_UPDATE (T6; a new announce key after another teammate was removed); on the
/// spaces service (v0.6.0, S6) SPACE_HEADS and SPACE_FETCH, answered with heads and with one
/// version in SPACE_VERSION and SPACE_CHUNK frames. Each service refuses the other's requests.
///
/// A SIGMA-style handshake over X25519 ephemerals, authenticated by each device's Ed25519 key
/// from pairing. No code is compared:
///
/// 1. I → R: `PREAMBLE(team)`, `HELLO_I = ver ‖ ephPK_I ‖ n_I`.
/// 2. R → I: `HELLO_R = ver ‖ ephPK_R ‖ n_R`. Both derive
///    `TH = SHA256(LP(transcript label) ‖ ver ‖ LP(ephPK_I) ‖ LP(n_I) ‖ LP(ephPK_R) ‖ LP(n_R))`
///    and the direction keys from `X25519(eph_I, eph_R)` salted with TH (the team labels).
/// 3. I → R (encrypted): `AUTH_I = deviceID_I ‖ sig_I(LP(auth-i) ‖ LP(TH) ‖ LP(deviceID_I) ‖
///    LP(deviceID_R))`, naming the teammate I meant to reach.
/// 4. R checks that the device is a teammate, that it meant R, and the signature; otherwise it
///    aborts without having said who it is. Then (encrypted) `AUTH_R = deviceID_R ‖
///    sig_R(LP(auth-r) ‖ LP(TH) ‖ LP(deviceID_I) ‖ LP(deviceID_R))`.
/// 5. I checks it is the teammate it meant and the signature.
///
/// Every signature covers TH, which binds both ephemerals, so a relay that runs its own
/// handshakes on both sides cannot reuse one. R reveals its identity only to a teammate; I
/// reveals its own to whoever answers at the pseudonym it chose (docs/SECURITY-MODEL.md §10.2).
public struct TeamSessionMachine: Sendable {
    public let role: NearbyRole
    /// What the session is for: its preamble, and the requests it allows.
    public let service: TeamService
    public private(set) var phase: TeamSessionPhase = .idle
    /// The authenticated teammate once AUTH passed.
    public private(set) var peer: TeamCardModel?

    private let keys: TeamDeviceKeys
    /// I: the teammate it means to reach. R: every teammate.
    private let teammates: [TeamDeviceID: TeamCardModel]
    private let expectedPeer: TeamDeviceID?
    private var ephemeral: NearbyKeyMaterial?
    private var helloI: Data?
    private var transcriptHash: Data?
    private var channel: NearbyChannel?
    /// I: the version arriving in SPACE_CHUNK frames (its announced length and the bytes so far).
    private var incomingVersion: (length: Int, bytes: Data)?

    /// I: a session to `peer` (found by its pseudonym, or at its address for `.spaces`).
    public static func initiator(
        keys: TeamDeviceKeys,
        peer: TeamCardModel,
        service: TeamService = .team,
        keyMaterial: NearbyKeyMaterial = .random()
    ) -> TeamSessionMachine {
        TeamSessionMachine(
            role: .initiator,
            service: service,
            keys: keys,
            teammates: [peer.deviceID: peer],
            expectedPeer: peer.deviceID,
            keyMaterial: keyMaterial
        )
    }

    /// R: answers any of `teammates` (the preamble was already read by the listener).
    public static func responder(
        keys: TeamDeviceKeys,
        teammates: [TeamCardModel],
        service: TeamService = .team,
        keyMaterial: NearbyKeyMaterial = .random()
    ) -> TeamSessionMachine {
        TeamSessionMachine(
            role: .responder,
            service: service,
            keys: keys,
            teammates: Dictionary(teammates.map { ($0.deviceID, $0) }, uniquingKeysWith: { first, _ in first }),
            expectedPeer: nil,
            keyMaterial: keyMaterial
        )
    }

    private init(
        role: NearbyRole,
        service: TeamService,
        keys: TeamDeviceKeys,
        teammates: [TeamDeviceID: TeamCardModel],
        expectedPeer: TeamDeviceID?,
        keyMaterial: NearbyKeyMaterial
    ) {
        self.role = role
        self.service = service
        self.keys = keys
        self.teammates = teammates
        self.expectedPeer = expectedPeer
        ephemeral = keyMaterial
    }

    // MARK: - Actions

    /// The transport connected: I sends the preamble and HELLO_I; R waits.
    public mutating func start() throws(ShareError) -> TeamSessionStep {
        guard phase == .idle, let ephemeral else { throw .nearbyActionNotAllowed }
        phase = .awaitingHello
        guard role == .initiator else { return .none }
        let hello = Self.hello(.helloInitiator, publicKey: ephemeral.publicKey, nonce: ephemeral.nonce)
        helloI = hello
        return TeamSessionStep(frames: [service.preamble, hello])
    }

    /// I: pings the authenticated teammate.
    public mutating func ping() throws(ShareError) -> TeamSessionStep {
        guard service == .team else { throw .nearbyActionNotAllowed }
        return try send(.ping, Data())
    }

    /// I: sends this device's card with its new announce key (same keys, same id).
    public mutating func updateCard(_ card: TeamCardModel) throws(ShareError) -> TeamSessionStep {
        guard service == .team, card.deviceID == keys.deviceID, card.announceKey == keys.announceKey else {
            throw .nearbyActionNotAllowed
        }
        return try send(.cardUpdate, card.encoded())
    }

    /// I (spaces service): this Mac's heads of the spaces it shares with the teammate.
    public mutating func requestSpaceHeads(_ heads: [SpaceHeadModel]) throws(ShareError) -> TeamSessionStep {
        guard service == .spaces, heads.count <= SpaceProtocol.maxHeads else { throw .nearbyActionNotAllowed }
        return try send(.spaceHeads, TeamSpaceWire.encode(heads))
    }

    /// I (spaces service): asks for one version.
    public mutating func requestSpaceVersion(_ spaceID: SpaceID, version: UInt64) throws(ShareError) -> TeamSessionStep {
        guard service == .spaces else { throw .nearbyActionNotAllowed }
        return try send(.spaceFetch, TeamSpaceWire.encodeFetch(spaceID, version: version))
    }

    /// R (spaces service): answers SPACE_HEADS with this Mac's heads of the spaces it shares
    /// with the teammate.
    public mutating func answerSpaceHeads(_ heads: [SpaceHeadModel]) -> TeamSessionStep {
        guard role == .responder, phase == .answering, heads.count <= SpaceProtocol.maxHeads else {
            return abort(.unexpectedMessage)
        }
        do {
            let frame = try seal(.spaceHeadsReply, TeamSpaceWire.encode(heads))
            phase = .ready
            return TeamSessionStep(frames: [frame])
        } catch {
            return abort(error.reason)
        }
    }

    /// R (spaces service): answers SPACE_FETCH with the version (nil: not sent).
    public mutating func answerSpaceVersion(_ version: Data?) -> TeamSessionStep {
        guard role == .responder, phase == .answering, (version?.count ?? 0) <= SpaceProtocol.maxVersionBytes else {
            return abort(.unexpectedMessage)
        }
        do {
            var body = Data()
            body.appendBigEndian(UInt32(version?.count ?? 0))
            var frames = [try seal(.spaceVersion, body)]
            if let version, !version.isEmpty, var current = channel {
                frames += try current.sealChunks(TeamMessageType.spaceChunk.rawValue, version)
                channel = current
            }
            phase = .ready
            return TeamSessionStep(frames: frames)
        } catch {
            return abort(error.reason)
        }
    }

    private mutating func send(_ type: TeamMessageType, _ body: Data) throws(ShareError) -> TeamSessionStep {
        guard role == .initiator, phase == .ready else { throw .nearbyActionNotAllowed }
        do {
            let frame = try seal(type, body)
            phase = .awaitingAnswer
            return TeamSessionStep(frames: [frame])
        } catch {
            return abort(error.reason)
        }
    }

    /// Ends the session normally (CLOSE).
    public mutating func close() -> TeamSessionStep {
        guard !phase.isTerminal else { return .none }
        let frames = (try? seal(.close, Data())).map { [$0] } ?? []
        wipe()
        phase = .finished
        return TeamSessionStep(frames: frames, events: [.finished])
    }

    /// Ends the session for `reason` and wipes the keys.
    public mutating func abort(_ reason: NearbyAbortReason) -> TeamSessionStep {
        guard !phase.isTerminal else { return .none }
        var frames: [Data] = []
        switch reason {
        case .disconnected, .peerAborted:
            break
        default:
            if channel != nil {
                if let frame = try? seal(.abort, Data([reason.code.rawValue])) {
                    frames.append(frame)
                }
            } else if phase != .idle {
                frames.append(Data([TeamMessageType.abort.rawValue, reason.code.rawValue]))
            }
        }
        let happenedAfterKeys = channel != nil
        incomingVersion?.bytes.wipe()
        incomingVersion = nil
        wipe()
        phase = .aborted
        return TeamSessionStep(
            frames: frames,
            events: [.aborted(NearbyAbortModel(reason: reason, happenedAfterReveal: happenedAfterKeys))]
        )
    }

    // MARK: - Peer frames

    public mutating func receive(_ frame: Data) -> TeamSessionStep {
        guard !phase.isTerminal, phase != .idle else { return .none }
        do {
            if channel == nil {
                return try receivePlaintext(frame)
            }
            if channel?.hasReceived != true, frame.count == 2, frame.first == TeamMessageType.abort.rawValue {
                return abort(.peerAborted(NearbyAbortCode(rawValue: frame[frame.startIndex + 1]) ?? .protocolError))
            }
            return try receiveEncrypted(frame)
        } catch {
            return abort(error.reason)
        }
    }

    private mutating func receivePlaintext(_ frame: Data) throws(NearbyFailure) -> TeamSessionStep {
        guard frame.count <= Limits.maxNearbyHandshakeFrameBytes else { throw NearbyFailure(.oversizeFrame) }
        if frame.count == 2, frame.first == TeamMessageType.abort.rawValue {
            return abort(.peerAborted(NearbyAbortCode(rawValue: frame[frame.startIndex + 1]) ?? .protocolError))
        }
        guard let ephemeral else { throw NearbyFailure(.cancelled) }
        switch role {
        case .responder:
            let (publicKey, _) = try Self.decodeHello(frame, type: .helloInitiator)
            let reply = Self.hello(.helloResponder, publicKey: ephemeral.publicKey, nonce: ephemeral.nonce)
            try establish(peerPublicKey: publicKey, helloI: frame, helloR: reply)
            phase = .authenticating
            return TeamSessionStep(frames: [reply])
        case .initiator:
            guard let helloI else { throw NearbyFailure(.unexpectedMessage) }
            let (publicKey, _) = try Self.decodeHello(frame, type: .helloResponder)
            try establish(peerPublicKey: publicKey, helloI: helloI, helloR: frame)
            phase = .authenticating
            return TeamSessionStep(frames: [try authFrame()])
        }
    }

    private mutating func receiveEncrypted(_ frame: Data) throws(NearbyFailure) -> TeamSessionStep {
        guard var current = channel else { throw NearbyFailure(.unexpectedMessage) }
        let (rawType, body) = try current.open(frame)
        channel = current
        guard let type = TeamMessageType(rawValue: rawType) else { throw NearbyFailure(.unexpectedMessage) }
        switch (type, phase, role) {
        case (.abort, _, _):
            return abort(.peerAborted(try NearbyMessageBody.decodeAbort(body)))
        case (.authInitiator, .authenticating, .responder):
            let peer = try verifiedAuth(body, type: .authInitiator)
            self.peer = peer
            phase = .ready
            return TeamSessionStep(frames: [try authFrame()], events: [.authenticated(peer)])
        case (.authResponder, .authenticating, .initiator):
            let peer = try verifiedAuth(body, type: .authResponder)
            self.peer = peer
            phase = .ready
            return TeamSessionStep(events: [.authenticated(peer)])
        case (.ping, .ready, .responder) where service == .team:
            guard body.isEmpty, let peer else { throw NearbyFailure(.malformedFrame) }
            return TeamSessionStep(frames: [try seal(.pong, Data())], events: [.pinged(peer)])
        case (.spaceHeads, .ready, .responder) where service == .spaces:
            guard let peer else { throw NearbyFailure(.unexpectedMessage) }
            let heads = try TeamSpaceWire.decodeHeads(body)
            phase = .answering
            return TeamSessionStep(events: [.spaceHeadsRequested(peer, heads)])
        case (.spaceFetch, .ready, .responder) where service == .spaces:
            guard let peer else { throw NearbyFailure(.unexpectedMessage) }
            let (spaceID, version) = try TeamSpaceWire.decodeFetch(body)
            phase = .answering
            return TeamSessionStep(events: [.spaceVersionRequested(peer, spaceID, version)])
        case (.spaceHeadsReply, .awaitingAnswer, .initiator) where service == .spaces && incomingVersion == nil:
            let heads = try TeamSpaceWire.decodeHeads(body)
            phase = .ready
            return TeamSessionStep(events: [.spaceHeadsAnswered(heads)])
        case (.spaceVersion, .awaitingAnswer, .initiator) where service == .spaces && incomingVersion == nil:
            var reader = NearbyByteReader(body)
            let length = Int(try reader.uint32())
            try reader.requireEnd()
            guard length <= SpaceProtocol.maxVersionBytes else { throw NearbyFailure(.oversizeFrame) }
            guard length > 0 else {
                phase = .ready
                return TeamSessionStep(events: [.spaceVersionAnswered(nil)])
            }
            incomingVersion = (length, Data())
            return .none
        case (.spaceChunk, .awaitingAnswer, .initiator) where service == .spaces:
            guard var incoming = incomingVersion, !body.isEmpty else { throw NearbyFailure(.unexpectedMessage) }
            guard incoming.bytes.count + body.count <= incoming.length else { throw NearbyFailure(.oversizeFrame) }
            incoming.bytes.append(body)
            guard incoming.bytes.count == incoming.length else {
                incomingVersion = incoming
                return .none
            }
            incomingVersion = nil
            phase = .ready
            return TeamSessionStep(events: [.spaceVersionAnswered(incoming.bytes)])
        case (.cardUpdate, .ready, .responder) where service == .team:
            let card = try TeamCardModel.decode(body)
            guard let peer,
                  card.deviceID == peer.deviceID,
                  card.signingPublicKey == peer.signingPublicKey,
                  card.agreementPublicKey == peer.agreementPublicKey
            else { throw NearbyFailure(.teammateNotRecognized) }
            self.peer = card
            return TeamSessionStep(frames: [try seal(.cardUpdated, Data())], events: [.cardUpdated(card)])
        case (.pong, .awaitingAnswer, .initiator) where service == .team:
            guard body.isEmpty else { throw NearbyFailure(.malformedFrame) }
            phase = .ready
            return TeamSessionStep(events: [.pingDelivered])
        case (.cardUpdated, .awaitingAnswer, .initiator) where service == .team:
            guard body.isEmpty else { throw NearbyFailure(.malformedFrame) }
            phase = .ready
            return TeamSessionStep(events: [.cardUpdateDelivered])
        case (.close, .ready, _), (.close, .awaitingAnswer, _):
            wipe()
            phase = .finished
            return TeamSessionStep(events: [.finished])
        default:
            throw NearbyFailure(.unexpectedMessage)
        }
    }

    // MARK: - Handshake

    private mutating func establish(peerPublicKey: Data, helloI: Data, helloR: Data) throws(NearbyFailure) {
        guard let ephemeral else { throw NearbyFailure(.cancelled) }
        let (publicKeyI, nonceI) = try Self.decodeHello(helloI, type: .helloInitiator)
        let (publicKeyR, nonceR) = try Self.decodeHello(helloR, type: .helloResponder)
        let secret = try NearbyCrypto.sharedSecret(privateKey: ephemeral.privateKey, peerPublicKey: peerPublicKey)
        let hash = Self.transcriptHash(publicKeyI: publicKeyI, nonceI: nonceI, publicKeyR: publicKeyR, nonceR: nonceR)
        let keys = NearbyCrypto.deriveSession(sharedSecret: secret, transcriptHash: hash, labels: .team)
        channel = NearbyChannel(role: role, keys: keys)
        transcriptHash = hash
        self.ephemeral = nil
    }

    /// AUTH_I (I) or AUTH_R (R): this device's id and its signature over the transcript.
    private mutating func authFrame() throws(NearbyFailure) -> Data {
        guard let transcriptHash else { throw NearbyFailure(.unexpectedMessage) }
        let (initiatorID, responderID): (TeamDeviceID, TeamDeviceID)
        switch role {
        case .initiator:
            guard let expectedPeer else { throw NearbyFailure(.unexpectedMessage) }
            (initiatorID, responderID) = (keys.deviceID, expectedPeer)
        case .responder:
            guard let peer else { throw NearbyFailure(.unexpectedMessage) }
            (initiatorID, responderID) = (peer.deviceID, keys.deviceID)
        }
        let type: TeamMessageType = role == .initiator ? .authInitiator : .authResponder
        let message = Self.authMessage(type: type, transcriptHash: transcriptHash, initiator: initiatorID, responder: responderID)
        var body = keys.deviceID.bytes
        body.append(try keys.sign(message))
        return try seal(type, body)
    }

    /// The peer's AUTH: a known teammate (I: the expected one; R: one that meant this device)
    /// and a valid signature.
    private func verifiedAuth(_ body: Data, type: TeamMessageType) throws(NearbyFailure) -> TeamCardModel {
        guard let transcriptHash else { throw NearbyFailure(.unexpectedMessage) }
        var reader = NearbyByteReader(body)
        guard let deviceID = TeamDeviceID(bytes: try reader.bytes(TeamProtocol.deviceIDBytes)) else {
            throw NearbyFailure(.malformedFrame)
        }
        let signature = try reader.bytes(TeamProtocol.signatureBytes)
        try reader.requireEnd()
        guard let card = teammates[deviceID], expectedPeer == nil || expectedPeer == deviceID else {
            throw NearbyFailure(.teammateNotRecognized)
        }
        let (initiatorID, responderID) = role == .initiator ? (keys.deviceID, deviceID) : (deviceID, keys.deviceID)
        let message = Self.authMessage(type: type, transcriptHash: transcriptHash, initiator: initiatorID, responder: responderID)
        guard card.isValidSignature(signature, for: message) else { throw NearbyFailure(.signatureInvalid) }
        return card
    }

    private mutating func seal(_ type: TeamMessageType, _ body: Data) throws(NearbyFailure) -> Data {
        guard var current = channel else { throw NearbyFailure(.unexpectedMessage) }
        defer { channel = current }
        return try current.seal(type.rawValue, body)
    }

    private mutating func wipe() {
        channel = nil
        ephemeral = nil
        transcriptHash = nil
    }

    /// Tests only: seals any frame type on the channel, as a misbehaving peer could.
    mutating func sealForTesting(_ type: TeamMessageType, _ body: Data) throws(NearbyFailure) -> [Data] {
        [try seal(type, body)]
    }

    // MARK: - Wire forms (internal for the known-answer tests)

    static func hello(_ type: TeamMessageType, publicKey: Data, nonce: Data) -> Data {
        var frame = Data([type.rawValue, TeamProtocol.version])
        frame.append(publicKey)
        frame.append(nonce)
        return frame
    }

    static func decodeHello(_ frame: Data, type: TeamMessageType) throws(NearbyFailure) -> (publicKey: Data, nonce: Data) {
        var reader = NearbyByteReader(frame)
        guard try reader.byte() == type.rawValue else { throw NearbyFailure(.unexpectedMessage) }
        guard try reader.byte() == TeamProtocol.version else { throw NearbyFailure(.unsupportedVersion) }
        let publicKey = try reader.bytes(NearbyProtocol.publicKeyBytes)
        let nonce = try reader.bytes(TeamProtocol.nonceBytes)
        try reader.requireEnd()
        return (publicKey, nonce)
    }

    /// `SHA256(LP(transcript label) ‖ ver ‖ LP(ephPK_I) ‖ LP(n_I) ‖ LP(ephPK_R) ‖ LP(n_R))`.
    static func transcriptHash(publicKeyI: Data, nonceI: Data, publicKeyR: Data, nonceR: Data) -> Data {
        var message = Data()
        message.appendLengthPrefixed(NearbyLabels.team.transcript)
        message.append(TeamProtocol.version)
        for field in [publicKeyI, nonceI, publicKeyR, nonceR] {
            message.appendLengthPrefixed(field)
        }
        return Data(SHA256.hash(data: message))
    }

    /// `LP(auth label) ‖ LP(TH) ‖ LP(deviceID_I) ‖ LP(deviceID_R)`.
    static func authMessage(
        type: TeamMessageType,
        transcriptHash: Data,
        initiator: TeamDeviceID,
        responder: TeamDeviceID
    ) -> Data {
        var message = Data()
        message.appendLengthPrefixed(type == .authInitiator ? TeamProtocol.initiatorAuthLabel : TeamProtocol.responderAuthLabel)
        message.appendLengthPrefixed(transcriptHash)
        message.appendLengthPrefixed(initiator.bytes)
        message.appendLengthPrefixed(responder.bytes)
        return message
    }
}
