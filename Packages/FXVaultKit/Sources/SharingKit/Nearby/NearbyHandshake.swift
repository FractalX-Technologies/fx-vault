import CryptoKit
import Foundation
import VaultCore

/// Where a nearby session is (§9.4). Drives the UI and the timers.
public enum NearbyPhase: String, Sendable, Hashable, CaseIterable {
    /// Created, `start()` not called yet.
    case idle
    /// I: HELLO_I sent, waiting for HELLO_R. R: waiting for HELLO_I.
    case awaitingHello
    /// R: HELLO_R sent, waiting for REVEAL_I.
    case awaitingReveal
    /// Both: the code is shown; waiting for both users' confirmations.
    case comparingCodes
    /// I: both confirmed; the app runs ReauthGate(.nearbySend) and then sends the manifest.
    case readyForManifest
    /// R: both confirmed; waiting for the first MANIFEST frame.
    case awaitingManifest
    /// R: MANIFEST frames arriving.
    case receivingManifest
    /// I: manifest sent; the receiver's user is deciding.
    case awaitingDecision
    /// R: manifest received; the local user is deciding.
    case reviewingManifest
    /// I: accepted; the app builds and sends the payload.
    case readyForPayload
    /// R: accepted; PAYLOAD frames arriving.
    case receivingPayload
    /// I: payload sent; the receiver's user confirms Same/Differs.
    case awaitingResult
    /// R: payload received; the local user confirms, then the app sends RESULT.
    case reviewingPayload
    /// Ended normally (transferred or declined).
    case finished
    /// Ended by an abort. Final: no resume, no retry.
    case aborted

    /// Whether the session has ended.
    public var isTerminal: Bool {
        self == .finished || self == .aborted
    }

    /// The phase timer that applies (the session timer always applies too). Phases that wait
    /// for a person on either side have no phase timer: only the session limit bounds them.
    public var timeoutKind: NearbyTimeoutKind? {
        switch self {
        case .awaitingHello, .awaitingReveal: .handshake
        case .comparingCodes: .sas
        case .receivingManifest, .receivingPayload: .idle
        default: nil
        }
    }
}

/// How a session ended normally.
public enum NearbyCompletion: Sendable, Hashable {
    /// I: the receiver reported its result.
    case transferred(receiverOK: Bool)
    /// R: the result was sent.
    case resultSent(ok: Bool)
    /// The receiver declined the manifest.
    case declined
}

/// Something the UI must react to.
public enum NearbyEvent: Sendable, Equatable {
    /// Keys exist: show the code and the peer name, with "Codes match" / "Don't match".
    case sasReady(NearbySASModel)
    /// The peer's user confirmed the code.
    case peerConfirmedSAS
    /// I: both users confirmed; run ReauthGate, then send the manifest.
    case readyForManifest
    /// R: the manifest (no values) to preview.
    case manifestReceived(SharePackageModel)
    /// I: the receiver's decision.
    case decisionReceived(NearbyDecisionModel)
    /// R: the accepted payload (with values) for the Same/Differs confirmation.
    case payloadReceived(SharePackageModel)
    case completed(NearbyCompletion)
    case aborted(NearbyAbortModel)
}

/// Frames to send and events to surface after one input.
public struct NearbyStep: Sendable, Equatable {
    public var frames: [Data]
    public var events: [NearbyEvent]

    public init(frames: [Data] = [], events: [NearbyEvent] = []) {
        self.frames = frames
        self.events = events
    }

    static let none = NearbyStep()
}

/// The transport-agnostic nearby share protocol v1 state machine (§9.4, D21).
///
/// The handshake, the code confirmation and the encrypted channel are ``NearbyKeyExchange``
/// with the share labels; this type adds the share phases and messages (MANIFEST, DECISION,
/// PAYLOAD, RESULT).
///
/// Feed it peer frames with ``receive(_:)`` and user actions with the action methods; send
/// every returned frame in order and surface every event. Protocol violations never throw:
/// they abort, wipe the keys and return an ABORT frame (plaintext before keys, encrypted
/// after) plus `.aborted`. Calling an action in the wrong phase throws
/// `.nearbyActionNotAllowed` and changes nothing. Once ``phase`` is terminal every call is
/// ignored or throws `.nearbySessionFinished`: there is no resume and no automatic retry.
public struct NearbyHandshake: Sendable {
    public let role: NearbyRole
    public private(set) var phase: NearbyPhase = .idle

    private var exchange: NearbyKeyExchange
    private var manifest: SharePackageModel?
    private var acceptedIDs: Set<ShareEntryID> = []
    private var expectedManifestLength = 0
    private var buffer = Data()

    /// - Parameters:
    ///   - localName: this Mac's display name; sanitized (NFC, ≤ 63 bytes) before sending.
    ///   - keyMaterial: fresh per session; tests inject fixed material.
    public init(role: NearbyRole, localName: String, keyMaterial: NearbyKeyMaterial = .random()) {
        self.role = role
        exchange = NearbyKeyExchange(role: role, purpose: .share, localName: localName, keyMaterial: keyMaterial)
    }

    /// The code and peer name once keys exist.
    public var sas: NearbySASModel? {
        exchange.sas
    }

    // MARK: - User actions

    /// I sends HELLO_I; R starts waiting for it.
    public mutating func start() throws(ShareError) -> NearbyStep {
        try requirePhase(.idle)
        let hello: Data?
        do {
            hello = try exchange.start()
        } catch {
            throw .nearbySessionFinished
        }
        phase = .awaitingHello
        return NearbyStep(frames: hello.map { [$0] } ?? [])
    }

    /// "Codes match": sends CONFIRM.
    public mutating func confirmSAS() throws(ShareError) -> NearbyStep {
        try requirePhase(.comparingCodes)
        guard !exchange.localConfirmed else { throw .nearbyActionNotAllowed }
        var step = NearbyStep()
        do {
            step.frames.append(try exchange.confirm())
        } catch {
            return abort(error.reason)
        }
        advanceIfBothConfirmed(&step)
        return step
    }

    /// "Don't match": aborts and tells the peer.
    public mutating func rejectSAS() throws(ShareError) -> NearbyStep {
        try requirePhase(.comparingCodes)
        return abort(.sasRejected)
    }

    /// I: sends the manifest of `package` (values are stripped here). Only after both users
    /// confirmed; the app must have passed ReauthGate(.nearbySend) first (D30).
    public mutating func sendManifest(_ package: SharePackageModel) throws(ShareError) -> NearbyStep {
        try requireRole(.initiator)
        try requirePhase(.readyForManifest)
        let manifest = package.manifest()
        try SharePackageValidator.validate(manifest, mode: .manifest)
        let json = try SharePackageCoder.encode(manifest)
        defer { json.wipe() }
        guard json.count <= Limits.maxNearbyPayloadBytes else { throw .payloadTooLarge }
        var bytes = Data()
        bytes.appendBigEndian(UInt32(json.count))
        json.withUnsafeBytes { bytes.append(contentsOf: $0) }
        let frames: [Data]
        do {
            frames = try exchange.sealChunks(NearbyMessageType.manifest.rawValue, bytes)
        } catch {
            return abort(error.reason)
        }
        self.manifest = manifest
        phase = .awaitingDecision
        return NearbyStep(frames: frames)
    }

    /// R: sends the decision on the received manifest. Accepted ids must come from it.
    public mutating func sendDecision(_ decision: NearbyDecisionModel) throws(ShareError) -> NearbyStep {
        try requireRole(.responder)
        try requirePhase(.reviewingManifest)
        if decision.accept {
            guard let manifest,
                  !decision.itemIDs.isEmpty,
                  decision.itemIDs.count <= NearbyMessageBody.maxDecisionIDs,
                  decision.itemIDs.isSubset(of: manifest.allEntryIDs)
            else { throw .nearbyActionNotAllowed }
        }
        let frame: Data
        do {
            frame = try seal(.decision, NearbyMessageBody.decision(decision))
        } catch {
            return abort(error.reason)
        }
        guard decision.accept else {
            return finish(NearbyStep(frames: [frame]), completion: .declined)
        }
        acceptedIDs = decision.itemIDs
        buffer = Data()
        phase = .receivingPayload
        return NearbyStep(frames: [frame])
    }

    /// I: sends `package` restricted to the accepted ids (manifest ∩ itemIds), then
    /// PAYLOAD_END. `package` must be the full package the manifest was made from.
    public mutating func sendPayload(_ package: SharePackageModel) throws(ShareError) -> NearbyStep {
        try requireRole(.initiator)
        try requirePhase(.readyForPayload)
        let payload = package.filtered(to: acceptedIDs)
        guard let manifest, payload.manifest() == manifest.filtered(to: acceptedIDs) else {
            throw .nearbyActionNotAllowed
        }
        try SharePackageValidator.validate(payload, mode: .payload)
        let json = try SharePackageCoder.encode(payload)
        defer { json.wipe() }
        guard json.count <= Limits.maxNearbyPayloadBytes else { throw .payloadTooLarge }
        var bytes = json.withUnsafeBytes { Data($0) }
        defer { bytes.wipe() }
        let digest = Data(SHA256.hash(data: bytes))
        var frames: [Data]
        do {
            frames = try exchange.sealChunks(NearbyMessageType.payloadChunk.rawValue, bytes)
            frames.append(try seal(
                .payloadEnd,
                NearbyMessageBody.payloadEnd(length: UInt64(bytes.count), digest: digest)
            ))
        } catch {
            return abort(error.reason)
        }
        phase = .awaitingResult
        return NearbyStep(frames: frames)
    }

    /// R: reports the outcome after the user confirmed Same/Differs and the import ran.
    public mutating func sendResult(ok: Bool) throws(ShareError) -> NearbyStep {
        try requireRole(.responder)
        try requirePhase(.reviewingPayload)
        let frame: Data
        do {
            frame = try seal(.result, NearbyMessageBody.result(ok: ok))
        } catch {
            return abort(error.reason)
        }
        return finish(NearbyStep(frames: [frame]), completion: .resultSent(ok: ok))
    }

    /// Ends the session for a local reason (cancel, timeout, disconnect, second peer).
    /// Ignored once the session is terminal.
    public mutating func abort(_ reason: NearbyAbortReason) -> NearbyStep {
        guard !phase.isTerminal else { return .none }
        var step = NearbyStep()
        if let frame = abortFrame(for: reason) {
            step.frames.append(frame)
        }
        let model = NearbyAbortModel(reason: reason, happenedAfterReveal: exchange.hasKeys)
        wipe()
        phase = .aborted
        step.events.append(.aborted(model))
        return step
    }

    // MARK: - Peer frames

    /// Processes one frame from the peer. Frames after the session ended are ignored.
    public mutating func receive(_ frame: Data) -> NearbyStep {
        switch phase {
        case .idle:
            return abort(.unexpectedMessage)
        case .finished, .aborted:
            return .none
        default:
            break
        }
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

    // MARK: - Plaintext handshake

    private mutating func receivePlaintext(_ frame: Data) throws(NearbyFailure) -> NearbyStep {
        switch try exchange.receivePlaintext(frame) {
        case .peerAborted(let code):
            return abort(.peerAborted(code))
        case .answeredHello(let reply, _):
            phase = .awaitingReveal
            return NearbyStep(frames: [reply])
        case .established(let reply, let sas):
            phase = .comparingCodes
            return NearbyStep(frames: reply.map { [$0] } ?? [], events: [.sasReady(sas)])
        }
    }

    // MARK: - Encrypted messages

    private mutating func receiveEncrypted(_ frame: Data) throws(NearbyFailure) -> NearbyStep {
        let opened = try exchange.open(frame)
        let rawType = opened.type
        var body = opened.body
        // A PAYLOAD body is part of the values' JSON: the handlers copy what they keep, so the
        // decrypted plaintext is zeroed once it was dispatched.
        defer { body.wipe() }
        guard let type = NearbyMessageType(rawValue: rawType) else {
            throw NearbyFailure(.unexpectedMessage)
        }
        switch (type, role, phase) {
        case (.abort, _, _):
            return abort(.peerAborted(try NearbyMessageBody.decodeAbort(body)))
        case (.close, _, _):
            return abort(.peerAborted(.cancelled))
        case (.confirm, _, .comparingCodes):
            return try receivedConfirm(body)
        case (.manifest, .responder, .awaitingManifest), (.manifest, .responder, .receivingManifest):
            return try receivedManifestChunk(body)
        case (.decision, .initiator, .awaitingDecision):
            return try receivedDecision(body)
        case (.payloadChunk, .responder, .receivingPayload):
            return try receivedPayloadChunk(body)
        case (.payloadEnd, .responder, .receivingPayload):
            return try receivedPayloadEnd(body)
        case (.result, .initiator, .awaitingResult):
            let ok = try NearbyMessageBody.decodeResult(body)
            return finishWithClose(completion: .transferred(receiverOK: ok))
        default:
            throw NearbyFailure(.unexpectedMessage)
        }
    }

    private mutating func receivedConfirm(_ body: Data) throws(NearbyFailure) -> NearbyStep {
        try exchange.receiveConfirm(body)
        var step = NearbyStep(events: [.peerConfirmedSAS])
        advanceIfBothConfirmed(&step)
        return step
    }

    private mutating func advanceIfBothConfirmed(_ step: inout NearbyStep) {
        guard exchange.isConfirmed else { return }
        switch role {
        case .initiator:
            phase = .readyForManifest
            step.events.append(.readyForManifest)
        case .responder:
            phase = .awaitingManifest
        }
    }

    private mutating func receivedManifestChunk(_ body: Data) throws(NearbyFailure) -> NearbyStep {
        var chunk = body
        if phase == .awaitingManifest {
            let (length, rest) = try NearbyMessageBody.decodeManifestLength(body)
            guard length > 0, length <= Limits.maxNearbyPayloadBytes else {
                throw NearbyFailure(.payloadTooLarge)
            }
            expectedManifestLength = length
            buffer = Data()
            chunk = rest
            phase = .receivingManifest
        }
        guard buffer.count + chunk.count <= expectedManifestLength else {
            throw NearbyFailure(.malformedFrame)
        }
        buffer.append(chunk)
        guard buffer.count == expectedManifestLength else { return .none }
        let json = SecretBytes(wipingSource: &buffer)
        defer { json.wipe() }
        let received: SharePackageModel
        do {
            received = try SharePackageCoder.decode(json)
            try SharePackageValidator.validate(received, mode: .manifest)
        } catch {
            throw NearbyFailure(Self.abortReason(for: error))
        }
        manifest = received
        buffer = Data()
        phase = .reviewingManifest
        return NearbyStep(events: [.manifestReceived(received)])
    }

    private mutating func receivedDecision(_ body: Data) throws(NearbyFailure) -> NearbyStep {
        let decision = try NearbyMessageBody.decodeDecision(body)
        guard decision.accept else {
            var step = finishWithClose(completion: .declined)
            step.events.insert(.decisionReceived(decision), at: 0)
            return step
        }
        guard let manifest, decision.itemIDs.isSubset(of: manifest.allEntryIDs) else {
            throw NearbyFailure(.unknownItemIDs)
        }
        acceptedIDs = decision.itemIDs
        phase = .readyForPayload
        return NearbyStep(events: [.decisionReceived(decision)])
    }

    private mutating func receivedPayloadChunk(_ body: Data) throws(NearbyFailure) -> NearbyStep {
        guard buffer.count + body.count <= Limits.maxNearbyPayloadBytes else {
            throw NearbyFailure(.payloadTooLarge)
        }
        buffer.append(body)
        return .none
    }

    private mutating func receivedPayloadEnd(_ body: Data) throws(NearbyFailure) -> NearbyStep {
        let (length, digest) = try NearbyMessageBody.decodePayloadEnd(body)
        let actual = Data(SHA256.hash(data: buffer))
        let digestMatches = actual.withUnsafeBytes { lhs in
            digest.withUnsafeBytes { rhs in SecretBytes.constantTimeEquals(lhs, rhs) }
        }
        guard length == UInt64(buffer.count), digestMatches else {
            throw NearbyFailure(.payloadMismatch)
        }
        let json = SecretBytes(wipingSource: &buffer)
        buffer = Data()
        defer { json.wipe() }
        let payload: SharePackageModel
        do {
            payload = try SharePackageCoder.decode(json)
            try SharePackageValidator.validate(payload, mode: .payload)
        } catch {
            throw NearbyFailure(Self.abortReason(for: error))
        }
        guard let manifest, payload.manifest() == manifest.filtered(to: acceptedIDs) else {
            payload.wipeValues()
            throw NearbyFailure(.payloadMismatch)
        }
        phase = .reviewingPayload
        return NearbyStep(events: [.payloadReceived(payload)])
    }

    // MARK: - Helpers

    private func requirePhase(_ expected: NearbyPhase) throws(ShareError) {
        if phase.isTerminal { throw .nearbySessionFinished }
        guard phase == expected else { throw .nearbyActionNotAllowed }
    }

    private func requireRole(_ expected: NearbyRole) throws(ShareError) {
        if phase.isTerminal { throw .nearbySessionFinished }
        guard role == expected else { throw .nearbyActionNotAllowed }
    }

    private mutating func seal(_ type: NearbyMessageType, _ body: Data) throws(NearbyFailure) -> Data {
        try exchange.seal(type.rawValue, body)
    }

    private mutating func abortFrame(for reason: NearbyAbortReason) -> Data? {
        switch reason {
        case .disconnected, .peerAborted:
            return nil
        default:
            return exchange.abortFrame(code: reason.code)
        }
    }

    private mutating func finish(_ step: NearbyStep, completion: NearbyCompletion) -> NearbyStep {
        var step = step
        wipe()
        phase = .finished
        step.events.append(.completed(completion))
        return step
    }

    /// I ends the session after RESULT or a decline with a best-effort CLOSE.
    private mutating func finishWithClose(completion: NearbyCompletion) -> NearbyStep {
        let close = try? seal(.close, Data())
        return finish(NearbyStep(frames: close.map { [$0] } ?? []), completion: completion)
    }

    /// Drops every key and wipes buffers; there is no way to resume.
    private mutating func wipe() {
        exchange.wipe()
        buffer.wipe()
        buffer = Data()
        acceptedIDs = []
    }

    static func abortReason(for error: ShareError) -> NearbyAbortReason {
        if case .invalidPackage(let violation) = error {
            return .invalidPackage(violation)
        }
        return .malformedFrame
    }
}
