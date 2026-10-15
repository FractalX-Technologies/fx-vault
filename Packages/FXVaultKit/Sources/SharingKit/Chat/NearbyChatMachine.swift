import Foundation
import VaultCore

/// Frames to send, events to surface and work for the session after one input.
struct NearbyChatStep: Sendable, Equatable {
    var frames: [Data] = []
    var events: [NearbyChatEvent] = []
    /// Offers the peer requested: the session asks each offer's provider for the value.
    var payloadRequests: [ChatAttachmentID] = []
    /// A message or attachment frame was sent or received (restarts the chat idle timer).
    var isActivity = false

    static let none = NearbyChatStep()
}

/// The transport-agnostic `fxvault-chat/v1` state machine.
///
/// The handshake, the code confirmation and the encrypted channel are ``NearbyKeyExchange``
/// with the chat labels (purpose `.chat`), so a share peer can never complete it. After both
/// users confirm, it carries TEXT, the attachment frames, PING/PONG and CLOSE.
///
/// Like ``NearbyHandshake``: peer frames never throw (a violation aborts, wipes and returns an
/// ABORT frame plus `.aborted`), a user action in the wrong phase throws and changes nothing,
/// and a terminal phase is final. It keeps no message history: each message exists only in the
/// returned event. Attachment payloads are buffered only while they arrive and wiped once
/// delivered, on close and on abort.
struct NearbyChatMachine: Sendable {
    private struct OutgoingOffer: Sendable {
        let manifest: SharePackageModel
        var isRequested = false
    }

    private enum IncomingState: Sendable {
        case offered
        case requested
        case receiving
    }

    private struct IncomingOffer: Sendable {
        let manifest: SharePackageModel
        var state = IncomingState.offered
    }

    private struct IncomingTransfer: Sendable {
        let id: ChatAttachmentID
        let totalLength: Int
        var buffer = Data()

        /// Reserves the whole payload at once, so appending chunks never reallocates and leaves
        /// an unwiped partial copy of the value behind.
        init(id: ChatAttachmentID, totalLength: Int) {
            self.id = id
            self.totalLength = totalLength
            buffer.reserveCapacity(totalLength)
        }

        var isComplete: Bool {
            buffer.count == totalLength
        }

        /// Moves the bytes into a wiped-on-release buffer and zeroes the original in place.
        mutating func takeJSON() -> SecretBytes {
            SecretBytes(wipingSource: &buffer)
        }
    }

    let role: NearbyRole
    private(set) var phase: NearbyChatPhase = .idle

    private var exchange: NearbyKeyExchange
    private var outgoing: [ChatAttachmentID: OutgoingOffer] = [:]
    private var incoming: [ChatAttachmentID: IncomingOffer] = [:]
    private var transfer: IncomingTransfer?
    /// PINGs sent and not yet answered by a PONG.
    private(set) var unansweredPings = 0
    /// Start of the current flood window and the peer frames counted in it.
    private var floodWindowStart: Date?
    private var floodWindowFrames = 0
    /// Offers the peer made in this chat.
    private var offersReceived = 0

    /// - Parameters:
    ///   - localName: this Mac's display name; sanitized (NFC, ≤ 63 bytes) before sending.
    ///   - keyMaterial: fresh per session; tests inject fixed material.
    ///   - maxVersion: the chat version to offer; nil is ``NearbyChatProtocol/maxVersion`` (tests
    ///     pin 1 to act as a 0.2.x or 0.3.x Mac).
    init(role: NearbyRole, localName: String, keyMaterial: NearbyKeyMaterial = .random(), maxVersion: UInt8? = nil) {
        self.role = role
        exchange = NearbyKeyExchange(
            role: role,
            purpose: .chat,
            localName: localName,
            keyMaterial: keyMaterial,
            maxVersion: maxVersion
        )
    }

    /// The code and peer name once keys exist.
    var sas: NearbySASModel? {
        exchange.sas
    }

    /// True once keys exist and both Macs speak chat v2 or later (v0.4.0): a whole repository or
    /// environment may be attached. False with a 0.2.x or 0.3.x peer.
    var acceptsConfigurationAttachments: Bool {
        (exchange.version ?? 0) >= NearbyChatProtocol.configurationAttachmentsVersion
    }

    /// True when nothing sensitive is held: no keys, no offers, no partial payload.
    var holdsNothing: Bool {
        !exchange.hasKeys && outgoing.isEmpty && incoming.isEmpty && transfer == nil
    }

    // MARK: - Lifecycle

    /// Arms the chat; the handshake starts once the transport connects.
    mutating func start() throws(ChatError) -> NearbyChatStep {
        try requirePhase(.idle)
        phase = .awaitingPeer
        return .none
    }

    /// The transport connected: I sends HELLO_I, R waits for it (and reports
    /// `.incomingConnection`).
    mutating func transportConnected() -> NearbyChatStep {
        guard phase == .awaitingPeer else { return .none }
        do {
            let hello = try exchange.start()
            phase = .awaitingHello
            return NearbyChatStep(
                frames: hello.map { [$0] } ?? [],
                events: role == .responder ? [.incomingConnection] : []
            )
        } catch {
            return abort(error.reason)
        }
    }

    /// "Codes match": sends CONFIRM.
    mutating func confirmSAS() throws(ChatError) -> NearbyChatStep {
        try requirePhase(.comparingCodes)
        guard !exchange.localConfirmed else { throw .actionNotAllowed }
        var step = NearbyChatStep()
        do {
            step.frames.append(try exchange.confirm())
        } catch {
            return abort(error.reason)
        }
        advanceIfBothConfirmed(&step)
        return step
    }

    /// "Don't match": aborts and tells the peer.
    mutating func rejectSAS() throws(ChatError) -> NearbyChatStep {
        try requirePhase(.comparingCodes)
        return abort(.sasRejected)
    }

    /// Ends the chat: CLOSE once verified, an ABORT (cancelled) during the handshake, and
    /// nothing at all before a peer connected. Idempotent.
    mutating func close() -> NearbyChatStep {
        switch phase {
        case .closed, .aborted:
            return .none
        case .idle, .awaitingPeer:
            wipe()
            phase = .closed
            return .none
        case .chatting:
            let frame = try? seal(.close, Data())
            wipe()
            phase = .closed
            return NearbyChatStep(frames: frame.map { [$0] } ?? [])
        case .awaitingHello, .awaitingReveal, .comparingCodes:
            return abort(.cancelled)
        }
    }

    /// Ends the chat for a local reason (timeout, disconnect, second peer, cancel). Ignored once
    /// the chat is terminal.
    mutating func abort(_ reason: NearbyAbortReason) -> NearbyChatStep {
        guard !phase.isTerminal else { return .none }
        var step = NearbyChatStep()
        if let frame = abortFrame(for: reason) {
            step.frames.append(frame)
        }
        let model = NearbyAbortModel(reason: reason, happenedAfterReveal: exchange.hasKeys)
        wipe()
        phase = .aborted
        step.events.append(.aborted(model))
        return step
    }

    /// One keepalive interval passed: sends PING, or aborts when the peer left
    /// ``Limits/chatMaxUnansweredPings`` PINGs unanswered.
    mutating func keepaliveTick() -> NearbyChatStep {
        guard phase == .chatting else { return .none }
        guard unansweredPings < Limits.chatMaxUnansweredPings else {
            return abort(.timeout(.keepalive))
        }
        do {
            let frame = try seal(.ping, Data())
            unansweredPings += 1
            return NearbyChatStep(frames: [frame])
        } catch {
            return abort(error.reason)
        }
    }

    // MARK: - Messages

    /// Sanitizes and sends one message. Returns the message as sent (nil if sealing aborted).
    mutating func sendText(_ text: String, at date: Date) throws(ChatError) -> (NearbyChatStep, ChatMessageModel?) {
        try requirePhase(.chatting)
        let sanitized = ChatTextSanitizer.sanitize(text)
        guard !sanitized.isEmpty else { throw .emptyMessage }
        var body = Data(sanitized.utf8)
        defer { body.wipe() }
        guard body.count <= Limits.chatMessageBytes else { throw .messageTooLarge }
        do {
            let frame = try seal(.text, body)
            let message = ChatMessageModel(direction: .sent, text: sanitized, date: date)
            return (NearbyChatStep(frames: [frame], isActivity: true), message)
        } catch {
            return (abort(error.reason), nil)
        }
    }

    // MARK: - Attachments (sender)

    /// Offers one secret or variable or, in a chat v2, a whole repository or environment.
    /// `manifest` may still hold values: they are stripped here.
    mutating func offerAttachment(
        _ manifest: SharePackageModel,
        id: ChatAttachmentID = ChatAttachmentID()
    ) throws(ChatError) -> (NearbyChatStep, ChatAttachmentOfferModel?) {
        try requirePhase(.chatting)
        let stripped = manifest.manifest()
        if stripped.scope != .secret, !acceptsConfigurationAttachments {
            throw .peerNeedsUpdate
        }
        guard Self.attachmentViolation(stripped, acceptsConfiguration: acceptsConfigurationAttachments) == nil,
              outgoing[id] == nil,
              incoming[id] == nil,
              let offer = ChatAttachmentOfferModel(id: id, direction: .sent, manifest: stripped)
        else { throw .invalidAttachment }
        guard outgoing.count < Limits.chatMaxOpenAttachments else { throw .tooManyAttachments }
        let json: SecretBytes
        do {
            json = try SharePackageCoder.encode(stripped)
        } catch {
            throw .invalidAttachment
        }
        defer { json.wipe() }
        var body = Data(id.bytes)
        json.withUnsafeBytes { body.append(contentsOf: $0) }
        guard body.count <= NearbyProtocol.maxFramePlaintextBytes else { throw .attachmentTooLarge }
        do {
            let frame = try seal(.attachmentOffer, body)
            outgoing[id] = OutgoingOffer(manifest: stripped)
            return (NearbyChatStep(frames: [frame], isActivity: true), offer)
        } catch {
            return (abort(error.reason), nil)
        }
    }

    /// Sends the payload of a requested item offer: the offered manifest with `value` filled in.
    /// Does not keep or wipe `value`; the caller wipes it.
    mutating func sendAttachmentPayload(_ id: ChatAttachmentID, value: SecretBytes) throws(ChatError) -> NearbyChatStep {
        try requirePhase(.chatting)
        guard let offer = outgoing[id], offer.isRequested else { throw .unknownAttachment }
        guard offer.manifest.scope == .secret else { throw .invalidAttachment }
        var payload = offer.manifest
        payload.repository = payload.repository.mapItems { item in
            var filled = item
            filled.value = value
            filled.valueState = .present
            return filled
        }
        return try sendPayload(id, payload)
    }

    /// Sends the payload of a requested configuration offer (v0.4.0): `package` must be the
    /// offered manifest with its values. Does not keep or wipe `package`; the caller wipes it.
    mutating func sendAttachmentPayload(_ id: ChatAttachmentID, package: SharePackageModel) throws(ChatError) -> NearbyChatStep {
        try requirePhase(.chatting)
        guard let offer = outgoing[id], offer.isRequested else { throw .unknownAttachment }
        guard offer.manifest.scope != .secret, package.manifest() == offer.manifest else {
            throw .invalidAttachment
        }
        return try sendPayload(id, package)
    }

    /// Validates, encodes and chunks a payload, then forgets the offer.
    private mutating func sendPayload(_ id: ChatAttachmentID, _ payload: SharePackageModel) throws(ChatError) -> NearbyChatStep {
        guard SharePackageValidator.violation(in: payload, mode: .payload) == nil else {
            throw .invalidAttachment
        }
        let json: SecretBytes
        do {
            json = try SharePackageCoder.encode(payload)
        } catch {
            throw .invalidAttachment
        }
        defer { json.wipe() }
        guard json.count <= Self.payloadLimit(for: payload.scope) else { throw .attachmentTooLarge }
        var bytes = json.withUnsafeBytes { Data($0) }
        defer { bytes.wipe() }
        var prefix = Data(id.bytes)
        prefix.appendBigEndian(UInt32(bytes.count))
        do {
            let frames = try exchange.sealChunks(
                NearbyChatMessageType.attachmentPayload.rawValue,
                bytes,
                prefix: prefix
            )
            outgoing[id] = nil
            return NearbyChatStep(frames: frames, events: [.attachmentSent(id)], isActivity: true)
        } catch {
            return abort(error.reason)
        }
    }

    /// The value for a requested offer could not be supplied: tells the peer (DECLINE) and
    /// forgets the offer.
    mutating func withdrawAttachment(_ id: ChatAttachmentID) -> NearbyChatStep {
        guard phase == .chatting, outgoing.removeValue(forKey: id) != nil else { return .none }
        do {
            return NearbyChatStep(frames: [try seal(.attachmentDecline, Data(id.bytes))])
        } catch {
            return abort(error.reason)
        }
    }

    // MARK: - Attachments (receiver)

    /// "Save to my vault": asks the sender for the value of an offer.
    mutating func requestAttachment(_ id: ChatAttachmentID) throws(ChatError) -> NearbyChatStep {
        try requirePhase(.chatting)
        guard incoming[id]?.state == .offered else { throw .unknownAttachment }
        do {
            let frame = try seal(.attachmentRequest, Data(id.bytes))
            incoming[id]?.state = .requested
            return NearbyChatStep(frames: [frame], isActivity: true)
        } catch {
            return abort(error.reason)
        }
    }

    /// "Dismiss": declines an offer that was not requested.
    mutating func declineAttachment(_ id: ChatAttachmentID) throws(ChatError) -> NearbyChatStep {
        try requirePhase(.chatting)
        guard incoming[id]?.state == .offered else { throw .unknownAttachment }
        do {
            let frame = try seal(.attachmentDecline, Data(id.bytes))
            incoming[id] = nil
            return NearbyChatStep(frames: [frame], isActivity: true)
        } catch {
            return abort(error.reason)
        }
    }

    // MARK: - Peer frames

    /// Processes one frame from the peer. Frames after the chat ended are ignored.
    mutating func receive(_ frame: Data, at date: Date) -> NearbyChatStep {
        switch phase {
        case .idle, .awaitingPeer:
            return abort(.unexpectedMessage)
        case .closed, .aborted:
            return .none
        case .awaitingHello, .awaitingReveal, .comparingCodes, .chatting:
            break
        }
        do {
            if !exchange.hasKeys {
                return try receivePlaintext(frame)
            }
            if let code = try exchange.plaintextAbortCode(frame) {
                return abort(.peerAborted(code))
            }
            return try receiveEncrypted(frame, at: date)
        } catch {
            return abort(error.reason)
        }
    }

    private mutating func receivePlaintext(_ frame: Data) throws(NearbyFailure) -> NearbyChatStep {
        switch try exchange.receivePlaintext(frame) {
        case .peerAborted(let code):
            return abort(.peerAborted(code))
        case .answeredHello(let reply, let peerName):
            phase = .awaitingReveal
            return NearbyChatStep(frames: [reply], events: [.peerConnected(name: peerName)])
        case .established(let reply, let sas):
            phase = .comparingCodes
            var events: [NearbyChatEvent] = role == .initiator ? [.peerConnected(name: sas.peerName)] : []
            events.append(.sasReady(sas))
            return NearbyChatStep(frames: reply.map { [$0] } ?? [], events: events)
        }
    }

    private mutating func receiveEncrypted(_ frame: Data, at date: Date) throws(NearbyFailure) -> NearbyChatStep {
        let opened = try exchange.open(frame)
        let rawType = opened.type
        var body = opened.body
        // The decrypted body may hold part of a secret value (ATTACHMENT_PAYLOAD): every handler
        // copies what it keeps, so the plaintext is zeroed once it was dispatched.
        defer { body.wipe() }
        guard let type = NearbyChatMessageType(rawValue: rawType) else {
            throw NearbyFailure(.unexpectedMessage)
        }
        if phase == .chatting, Self.countsTowardFloodLimit(type) {
            try countPeerFrame(at: date)
        }
        switch (type, phase) {
        case (.abort, _):
            return abort(.peerAborted(try NearbyMessageBody.decodeAbort(body)))
        case (.close, .chatting):
            guard body.isEmpty else { throw NearbyFailure(.malformedFrame) }
            wipe()
            phase = .closed
            return NearbyChatStep(events: [.peerClosed])
        case (.close, _):
            return abort(.peerAborted(.cancelled))
        case (.confirm, .comparingCodes):
            try exchange.receiveConfirm(body)
            var step = NearbyChatStep(events: [.peerConfirmedSAS])
            advanceIfBothConfirmed(&step)
            return step
        case (.text, .chatting):
            return try receivedText(body, at: date)
        case (.attachmentOffer, .chatting):
            return try receivedOffer(body)
        case (.attachmentRequest, .chatting):
            return try receivedRequest(body)
        case (.attachmentPayload, .chatting):
            return try receivedPayloadChunk(body)
        case (.attachmentDecline, .chatting):
            return try receivedDecline(body)
        case (.ping, .chatting):
            guard body.isEmpty else { throw NearbyFailure(.malformedFrame) }
            return NearbyChatStep(frames: [try seal(.pong, Data())])
        case (.pong, .chatting):
            guard body.isEmpty else { throw NearbyFailure(.malformedFrame) }
            guard unansweredPings > 0 else { throw NearbyFailure(.unexpectedMessage) }
            unansweredPings -= 1
            return .none
        default:
            throw NearbyFailure(.unexpectedMessage)
        }
    }

    private mutating func advanceIfBothConfirmed(_ step: inout NearbyChatStep) {
        guard exchange.isConfirmed else { return }
        phase = .chatting
        step.events.append(.verified)
    }

    private func receivedText(_ body: Data, at date: Date) throws(NearbyFailure) -> NearbyChatStep {
        guard body.count <= Limits.chatMessageBytes else { throw NearbyFailure(.oversizeFrame) }
        guard !body.isEmpty, let text = String(data: body, encoding: .utf8) else {
            throw NearbyFailure(.malformedFrame)
        }
        let sanitized = ChatTextSanitizer.sanitize(text)
        guard !sanitized.isEmpty else { return NearbyChatStep(isActivity: true) }
        let message = ChatMessageModel(direction: .received, text: sanitized, date: date)
        return NearbyChatStep(events: [.message(message)], isActivity: true)
    }

    private mutating func receivedOffer(_ body: Data) throws(NearbyFailure) -> NearbyChatStep {
        var reader = NearbyByteReader(body)
        let id = try Self.attachmentID(&reader)
        guard incoming[id] == nil, outgoing[id] == nil else { throw NearbyFailure(.malformedFrame) }
        guard incoming.count < Limits.chatMaxOpenAttachments,
              offersReceived < Limits.chatMaxOffersPerChat
        else { throw NearbyFailure(.unexpectedMessage) }
        offersReceived += 1
        let json = SecretBytes(copying: reader.remaining())
        defer { json.wipe() }
        let manifest: SharePackageModel
        do {
            manifest = try SharePackageCoder.decode(json)
            try SharePackageValidator.validate(manifest, mode: .manifest)
        } catch {
            throw NearbyFailure(NearbyHandshake.abortReason(for: error))
        }
        if let reason = Self.attachmentViolation(manifest, acceptsConfiguration: acceptsConfigurationAttachments) {
            throw NearbyFailure(reason)
        }
        guard let offer = ChatAttachmentOfferModel(id: id, direction: .received, manifest: manifest) else {
            throw NearbyFailure(.invalidPackage(.scopeMismatch(manifest.scope)))
        }
        incoming[id] = IncomingOffer(manifest: manifest)
        return NearbyChatStep(events: [.attachmentOffered(offer)], isActivity: true)
    }

    private mutating func receivedRequest(_ body: Data) throws(NearbyFailure) -> NearbyChatStep {
        var reader = NearbyByteReader(body)
        let id = try Self.attachmentID(&reader)
        try reader.requireEnd()
        guard let offer = outgoing[id] else { throw NearbyFailure(.unknownItemIDs) }
        guard !offer.isRequested else { throw NearbyFailure(.unexpectedMessage) }
        outgoing[id]?.isRequested = true
        return NearbyChatStep(payloadRequests: [id], isActivity: true)
    }

    private mutating func receivedPayloadChunk(_ body: Data) throws(NearbyFailure) -> NearbyChatStep {
        var reader = NearbyByteReader(body)
        defer { reader.wipe() }
        let id = try Self.attachmentID(&reader)
        let totalLength = Int(try reader.uint32())
        var chunk = reader.remaining()
        defer { chunk.wipe() }
        guard !chunk.isEmpty else { throw NearbyFailure(.malformedFrame) }
        if transfer == nil {
            guard let offer = incoming[id] else { throw NearbyFailure(.unknownItemIDs) }
            guard offer.state == .requested else { throw NearbyFailure(.unexpectedMessage) }
            guard totalLength > 0, totalLength <= Self.payloadLimit(for: offer.manifest.scope) else {
                throw NearbyFailure(.payloadTooLarge)
            }
            transfer = IncomingTransfer(id: id, totalLength: totalLength)
            incoming[id]?.state = .receiving
        }
        guard transfer?.id == id else { throw NearbyFailure(.unexpectedMessage) }
        guard transfer?.totalLength == totalLength,
              let received = transfer?.buffer.count,
              received + chunk.count <= totalLength
        else { throw NearbyFailure(.payloadMismatch) }
        transfer?.buffer.append(chunk)
        guard transfer?.isComplete == true, let json = transfer?.takeJSON() else {
            return NearbyChatStep(isActivity: true)
        }
        transfer = nil
        defer { json.wipe() }
        guard let offer = incoming.removeValue(forKey: id) else { throw NearbyFailure(.unknownItemIDs) }
        let payload: SharePackageModel
        do {
            payload = try SharePackageCoder.decode(json)
            try SharePackageValidator.validate(payload, mode: .payload)
        } catch {
            throw NearbyFailure(NearbyHandshake.abortReason(for: error))
        }
        guard payload.manifest() == offer.manifest else {
            payload.wipeValues()
            throw NearbyFailure(.payloadMismatch)
        }
        return NearbyChatStep(events: [.attachmentReceived(id, payload)], isActivity: true)
    }

    private mutating func receivedDecline(_ body: Data) throws(NearbyFailure) -> NearbyChatStep {
        var reader = NearbyByteReader(body)
        let id = try Self.attachmentID(&reader)
        try reader.requireEnd()
        if let offer = outgoing[id] {
            // The receiver may dismiss only an offer it has not requested.
            guard !offer.isRequested else { throw NearbyFailure(.unexpectedMessage) }
            outgoing[id] = nil
        } else if let offer = incoming[id] {
            // The sender may withdraw an offer until its payload starts.
            guard offer.state != .receiving else { throw NearbyFailure(.unexpectedMessage) }
            incoming[id] = nil
        } else {
            throw NearbyFailure(.unknownItemIDs)
        }
        return NearbyChatStep(events: [.attachmentDeclined(id)], isActivity: true)
    }

    // MARK: - Helpers

    /// Frames a person causes; attachment payload chunks, PONG, CONFIRM, CLOSE and ABORT have
    /// limits of their own.
    private static func countsTowardFloodLimit(_ type: NearbyChatMessageType) -> Bool {
        switch type {
        case .text, .attachmentOffer, .attachmentRequest, .attachmentDecline, .ping: true
        case .confirm, .attachmentPayload, .pong, .close, .abort: false
        }
    }

    /// Counts one peer frame; throws `unexpectedMessage` beyond
    /// ``Limits/chatMaxPeerFramesPerFloodWindow`` within ``Timeouts/chatFloodWindow``.
    private mutating func countPeerFrame(at date: Date) throws(NearbyFailure) {
        if let start = floodWindowStart, date.timeIntervalSince(start) < Timeouts.chatFloodWindow.timeInterval {
            floodWindowFrames += 1
        } else {
            floodWindowStart = date
            floodWindowFrames = 1
        }
        guard floodWindowFrames <= Limits.chatMaxPeerFramesPerFloodWindow else {
            throw NearbyFailure(.unexpectedMessage)
        }
    }

    /// Chat attachments are one secret or variable that has a value (scope `secret`) or, in a
    /// chat v2 (v0.4.0), a whole repository or environment (scope `repository` or `environment`,
    /// values present or missing). Every one must pass the share validator (manifest mode).
    static func attachmentViolation(_ manifest: SharePackageModel, acceptsConfiguration: Bool) -> NearbyAbortReason? {
        if let violation = SharePackageValidator.violation(in: manifest, mode: .manifest) {
            return .invalidPackage(violation)
        }
        switch manifest.scope {
        case .secret:
            guard manifest.itemCount == 1 else { return .invalidPackage(.scopeMismatch(manifest.scope)) }
            guard manifest.flattenedItems.first?.item.valueState == .present else {
                return .invalidPackage(.valueStateMismatch)
            }
            return nil
        case .repository, .environment:
            return acceptsConfiguration ? nil : .invalidPackage(.scopeMismatch(manifest.scope))
        }
    }

    /// The largest payload JSON of an offer: one value, or a configuration (v0.4.0).
    static func payloadLimit(for scope: ShareScope) -> Int {
        scope == .secret ? Limits.chatAttachmentBytes : Limits.chatConfigurationAttachmentBytes
    }

    private static func attachmentID(_ reader: inout NearbyByteReader) throws(NearbyFailure) -> ChatAttachmentID {
        guard let id = ChatAttachmentID(bytes: try reader.bytes(NearbyChatProtocol.attachmentIDBytes)) else {
            throw NearbyFailure(.malformedFrame)
        }
        return id
    }

    private func requirePhase(_ expected: NearbyChatPhase) throws(ChatError) {
        if phase.isTerminal { throw .sessionFinished }
        guard phase == expected else { throw .actionNotAllowed }
    }

    private mutating func seal(_ type: NearbyChatMessageType, _ body: Data) throws(NearbyFailure) -> Data {
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

    /// Drops the keys, every offer and any partial payload (wiped in place).
    private mutating func wipe() {
        exchange.wipe()
        outgoing.removeAll()
        incoming.removeAll()
        transfer?.buffer.wipe()
        transfer = nil
        unansweredPings = 0
    }
}
