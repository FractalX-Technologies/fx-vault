import Foundation
import VaultCore

/// Where Add Teammate is (T2).
public enum TeamPairingPhase: String, Sendable, Hashable, CaseIterable {
    case idle
    /// HELLO through REVEAL.
    case awaitingHello
    /// The code is shown; both people compare it.
    case comparingCodes
    /// Both confirmed; the cards are crossing.
    case exchangingCards
    /// Both cards arrived and verified.
    case paired
    case aborted

    public var isTerminal: Bool {
        self == .paired || self == .aborted
    }

    /// The timer that applies (the same timers as a nearby share).
    public var timeoutKind: NearbyTimeoutKind? {
        switch self {
        case .awaitingHello: .handshake
        case .comparingCodes: .sas
        case .exchangingCards: .idle
        default: nil
        }
    }
}

/// Something Add Teammate must show.
public enum TeamPairingEvent: Sendable, Equatable {
    /// R: a Mac connected (the sheet stops listing people and waits for the code).
    case incomingConnection
    /// Keys exist: show the code and the peer's (unverified) name.
    case sasReady(NearbySASModel)
    case peerConfirmedSAS
    /// Both cards verified: store `card` as a teammate.
    case paired(TeamCardModel)
    case aborted(NearbyAbortModel)
}

/// Frames to send and events to show after one input.
public struct TeamPairingStep: Sendable, Equatable {
    public var frames: [Data] = []
    public var events: [TeamPairingEvent] = []

    static let none = TeamPairingStep()
}

/// Add Teammate (T2): the nearby commit-reveal handshake with the pair labels and the 6-digit
/// code both people compare, then each side sends its card (``TeamCardModel``) signed with its
/// device key over the transcript hash and its role, so a card cannot be replayed into another
/// pairing or reflected back. Pairing with this device's own card aborts.
///
/// Like the other nearby machines: peer frames never throw (a violation aborts and returns an
/// ABORT frame plus `.aborted`), an action in the wrong phase throws and changes nothing, and a
/// terminal phase is final.
public struct TeamPairingMachine: Sendable {
    public let role: NearbyRole
    public private(set) var phase: TeamPairingPhase = .idle

    private var exchange: NearbyKeyExchange
    private let keys: TeamDeviceKeys
    private let card: TeamCardModel
    private var hasSentCard = false
    private var peerCard: TeamCardModel?

    /// - Parameters:
    ///   - localName: the name shown in HELLO (sanitized).
    ///   - keys: this device's keys; they sign the card.
    ///   - card: this device's card (``TeamDeviceKeys/card(login:displayName:macName:)``).
    ///   - keyMaterial: fresh per session; tests inject fixed material.
    public init(
        role: NearbyRole,
        localName: String,
        keys: TeamDeviceKeys,
        card: TeamCardModel,
        keyMaterial: NearbyKeyMaterial = .random()
    ) {
        self.role = role
        self.keys = keys
        self.card = card
        exchange = NearbyKeyExchange(role: role, purpose: .pair, localName: localName, keyMaterial: keyMaterial)
    }

    /// The code and peer name once keys exist.
    public var sas: NearbySASModel? {
        exchange.sas
    }

    // MARK: - Actions

    /// The transport connected: I sends HELLO_I, R waits for it.
    public mutating func start() throws(ShareError) -> TeamPairingStep {
        guard phase == .idle else { throw .nearbyActionNotAllowed }
        do {
            let hello = try exchange.start()
            phase = .awaitingHello
            return TeamPairingStep(frames: hello.map { [$0] } ?? [])
        } catch {
            return abort(error.reason)
        }
    }

    /// "Codes match".
    public mutating func confirmSAS() throws(ShareError) -> TeamPairingStep {
        guard phase == .comparingCodes, !exchange.localConfirmed else { throw .nearbyActionNotAllowed }
        var step = TeamPairingStep()
        do {
            step.frames.append(try exchange.confirm())
            try advanceIfBothConfirmed(&step)
        } catch {
            return abort(error.reason)
        }
        return step
    }

    /// "Don't match".
    public mutating func rejectSAS() throws(ShareError) -> TeamPairingStep {
        guard phase == .comparingCodes else { throw .nearbyActionNotAllowed }
        return abort(.sasRejected)
    }

    /// Ends the pairing for `reason` (cancel, timeout, disconnect) and wipes the keys.
    public mutating func abort(_ reason: NearbyAbortReason) -> TeamPairingStep {
        guard !phase.isTerminal else { return .none }
        let happenedAfterReveal = exchange.hasKeys
        var frames: [Data] = []
        switch reason {
        case .disconnected, .peerAborted:
            break
        default:
            if let frame = exchange.abortFrame(code: reason.code) {
                frames.append(frame)
            }
        }
        wipe()
        phase = .aborted
        return TeamPairingStep(
            frames: frames,
            events: [.aborted(NearbyAbortModel(reason: reason, happenedAfterReveal: happenedAfterReveal))]
        )
    }

    // MARK: - Peer frames

    public mutating func receive(_ frame: Data) -> TeamPairingStep {
        guard !phase.isTerminal, phase != .idle else { return .none }
        do {
            if !exchange.hasKeys {
                return try receivePlaintext(frame)
            }
            if let code = try exchange.plaintextAbortCode(frame) {
                return abort(.peerAborted(code))
            }
            return try receiveEncrypted(frame)
        } catch {
            return abort(error.reason)
        }
    }

    private mutating func receivePlaintext(_ frame: Data) throws(NearbyFailure) -> TeamPairingStep {
        switch try exchange.receivePlaintext(frame) {
        case .peerAborted(let code):
            return abort(.peerAborted(code))
        case .answeredHello(let reply, _):
            return TeamPairingStep(frames: [reply], events: [.incomingConnection])
        case .established(let reply, let sas):
            phase = .comparingCodes
            return TeamPairingStep(frames: reply.map { [$0] } ?? [], events: [.sasReady(sas)])
        }
    }

    private mutating func receiveEncrypted(_ frame: Data) throws(NearbyFailure) -> TeamPairingStep {
        let (rawType, body) = try exchange.open(frame)
        guard let type = TeamMessageType(rawValue: rawType) else { throw NearbyFailure(.unexpectedMessage) }
        switch (type, phase) {
        case (.abort, _):
            return abort(.peerAborted(try NearbyMessageBody.decodeAbort(body)))
        case (.confirm, .comparingCodes):
            try exchange.receiveConfirm(body)
            var step = TeamPairingStep(events: [.peerConfirmedSAS])
            try advanceIfBothConfirmed(&step)
            return step
        case (.card, .exchangingCards) where peerCard == nil:
            peerCard = try verifiedCard(body)
            return finishIfComplete()
        case (.close, .paired):
            return .none
        default:
            throw NearbyFailure(.unexpectedMessage)
        }
    }

    // MARK: - Cards

    private mutating func advanceIfBothConfirmed(_ step: inout TeamPairingStep) throws(NearbyFailure) {
        guard exchange.isConfirmed, phase == .comparingCodes else { return }
        phase = .exchangingCards
        step.frames.append(try cardFrame())
        hasSentCard = true
    }

    /// `u16 length ‖ card ‖ Ed25519(LP(label) ‖ u8(role) ‖ LP(TH) ‖ LP(card))`.
    private mutating func cardFrame() throws(NearbyFailure) -> Data {
        guard let transcriptHash = exchange.transcriptHash else { throw NearbyFailure(.unexpectedMessage) }
        let bytes = card.encoded()
        let signature = try keys.sign(Self.signedCardMessage(role: role, transcriptHash: transcriptHash, card: bytes))
        var body = Data()
        body.appendBigEndian(UInt16(bytes.count))
        body.append(bytes)
        body.append(signature)
        return try exchange.seal(TeamMessageType.card.rawValue, body)
    }

    private func verifiedCard(_ body: Data) throws(NearbyFailure) -> TeamCardModel {
        guard let transcriptHash = exchange.transcriptHash else { throw NearbyFailure(.unexpectedMessage) }
        var reader = NearbyByteReader(body)
        let length = Int(try reader.uint16())
        let bytes = try reader.bytes(length)
        let signature = try reader.bytes(TeamProtocol.signatureBytes)
        try reader.requireEnd()
        let peer = try TeamCardModel.decode(bytes)
        let peerRole: NearbyRole = role == .initiator ? .responder : .initiator
        let message = Self.signedCardMessage(role: peerRole, transcriptHash: transcriptHash, card: bytes)
        guard peer.isValidSignature(signature, for: message) else { throw NearbyFailure(.signatureInvalid) }
        guard peer.deviceID != card.deviceID else { throw NearbyFailure(.teammateNotRecognized) }
        return peer
    }

    private mutating func finishIfComplete() -> TeamPairingStep {
        guard hasSentCard, let peerCard else { return .none }
        var frames: [Data] = []
        if let close = try? exchange.seal(TeamMessageType.close.rawValue, Data()) {
            frames.append(close)
        }
        wipe()
        phase = .paired
        return TeamPairingStep(frames: frames, events: [.paired(peerCard)])
    }

    /// What a card signature covers.
    static func signedCardMessage(role: NearbyRole, transcriptHash: Data, card: Data) -> Data {
        var message = Data()
        message.appendLengthPrefixed(TeamProtocol.cardSignatureLabel)
        message.append(role.wireByte)
        message.appendLengthPrefixed(transcriptHash)
        message.appendLengthPrefixed(card)
        return message
    }

    private mutating func wipe() {
        exchange.wipe()
    }
}

extension NearbyRole {
    /// `I` or `R`, as bound into teammate signatures.
    var wireByte: UInt8 {
        self == .initiator ? UInt8(ascii: "I") : UInt8(ascii: "R")
    }
}
