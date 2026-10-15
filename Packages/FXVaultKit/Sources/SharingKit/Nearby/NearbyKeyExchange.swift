import CryptoKit
import Foundation
import VaultCore

/// The part of the nearby protocol that share and chat have in common (§9.4 steps 1–6): the
/// commit-reveal X25519 handshake, the SAS, the CONFIRM exchange, and then the encrypted channel
/// with one key per direction and exact per-direction sequence numbers.
///
/// The purpose selects the labels (``NearbyLabels``), so the same code produces
/// domain-separated commitments, transcripts, codes and keys for share and chat. The owning
/// state machine (``NearbyHandshake`` for share, ``NearbyChatMachine`` for chat) tracks its own
/// phases, decides which encrypted message types are allowed, and turns every thrown
/// ``NearbyFailure`` into an abort.
struct NearbyKeyExchange: Sendable {
    /// What a plaintext handshake frame led to.
    enum PlaintextOutcome: Sendable {
        /// The peer sent a plaintext ABORT.
        case peerAborted(NearbyAbortCode)
        /// R: HELLO_I arrived and HELLO_R must be sent. The peer's name is unverified.
        case answeredHello(reply: Data, peerName: String)
        /// Keys exist and the code can be shown. I must send `reply` (REVEAL_I); R has none.
        case established(reply: Data?, sas: NearbySASModel)
    }

    private struct HelloInitiator: Sendable {
        let maxVersion: UInt8
        let suite: UInt8
        let commitment: Data
        let name: Data
    }

    let role: NearbyRole
    let purpose: NearbyPurpose
    /// The code and the peer's sanitized name once keys exist. Kept after ``wipe()``.
    private(set) var sas: NearbySASModel?
    private(set) var localConfirmed = false
    private(set) var remoteConfirmed = false

    private let localName: Data
    private var hasStarted = false
    private var keyMaterial: NearbyKeyMaterial?
    private var helloI: HelloInitiator?
    private var keys: NearbySessionKeys?
    private var sendSequence: UInt64 = 0
    private var receiveSequence: UInt64 = 0

    /// - Parameters:
    ///   - localName: this Mac's display name; sanitized (NFC, ≤ 63 bytes) before sending.
    ///   - keyMaterial: fresh per session; tests inject fixed material.
    init(role: NearbyRole, purpose: NearbyPurpose, localName: String, keyMaterial: NearbyKeyMaterial) {
        self.role = role
        self.purpose = purpose
        self.localName = Data(DisplayNameSanitizer.sanitize(localName).utf8)
        self.keyMaterial = keyMaterial
    }

    /// True once the shared secret was derived (REVEAL sent or received).
    var hasKeys: Bool {
        keys != nil
    }

    /// True once both users confirmed the code.
    var isConfirmed: Bool {
        localConfirmed && remoteConfirmed
    }

    // MARK: - Handshake

    /// Starts the handshake: I returns HELLO_I, R returns nil and waits for it.
    mutating func start() throws(NearbyFailure) -> Data? {
        guard !hasStarted, let keyMaterial else { throw NearbyFailure(.unexpectedMessage) }
        hasStarted = true
        guard role == .initiator else { return nil }
        let labels = purpose.labels
        let commitment = NearbyCrypto.commitment(
            maxVersion: NearbyProtocol.maxVersion,
            suite: NearbyProtocol.suite,
            publicKey: keyMaterial.publicKey,
            nonce: keyMaterial.nonce,
            labels: labels
        )
        helloI = HelloInitiator(
            maxVersion: NearbyProtocol.maxVersion,
            suite: NearbyProtocol.suite,
            commitment: commitment,
            name: localName
        )
        return NearbyHandshakeFrame.helloInitiator(
            maxVersion: NearbyProtocol.maxVersion,
            suite: NearbyProtocol.suite,
            commitment: commitment,
            name: localName
        ).encoded()
    }

    /// Processes one plaintext frame. Only valid before keys exist; anything out of order is
    /// `.unexpectedMessage`.
    mutating func receivePlaintext(_ frame: Data) throws(NearbyFailure) -> PlaintextOutcome {
        guard hasStarted, keys == nil else { throw NearbyFailure(.unexpectedMessage) }
        let decoded = try NearbyHandshakeFrame.decode(frame)
        switch (role, decoded) {
        case (_, .abort(let code)):
            return .peerAborted(NearbyAbortCode(rawValue: code) ?? .protocolError)
        case (.responder, .helloInitiator(let maxVersion, let suite, let commitment, let name)) where helloI == nil:
            return try responderReceivedHello(maxVersion: maxVersion, suite: suite, commitment: commitment, name: name)
        case (.initiator, .helloResponder(let maxVersion, let suite, let publicKey, let nonce, let name)):
            return try initiatorReceivedHello(
                maxVersion: maxVersion,
                suite: suite,
                publicKey: publicKey,
                nonce: nonce,
                name: name
            )
        case (.responder, .revealInitiator(let publicKey, let nonce)) where helloI != nil:
            return try responderReceivedReveal(publicKey: publicKey, nonce: nonce)
        default:
            throw NearbyFailure(.unexpectedMessage)
        }
    }

    /// R, step 2: answer HELLO_I with HELLO_R (only after C was received).
    private mutating func responderReceivedHello(
        maxVersion: UInt8,
        suite: UInt8,
        commitment: Data,
        name: Data
    ) throws(NearbyFailure) -> PlaintextOutcome {
        guard maxVersion >= NearbyProtocol.minVersion else { throw NearbyFailure(.unsupportedVersion) }
        guard suite == NearbyProtocol.suite else { throw NearbyFailure(.unsupportedSuite) }
        guard let keyMaterial else { throw NearbyFailure(.cancelled) }
        helloI = HelloInitiator(maxVersion: maxVersion, suite: suite, commitment: commitment, name: name)
        let frame = NearbyHandshakeFrame.helloResponder(
            maxVersion: NearbyProtocol.maxVersion,
            suite: NearbyProtocol.suite,
            publicKey: keyMaterial.publicKey,
            nonce: keyMaterial.nonce,
            name: localName
        )
        return .answeredHello(reply: frame.encoded(), peerName: Self.displayName(name))
    }

    /// I, steps 3–4: check version and suite, agree, derive, then REVEAL.
    private mutating func initiatorReceivedHello(
        maxVersion: UInt8,
        suite: UInt8,
        publicKey: Data,
        nonce: Data,
        name: Data
    ) throws(NearbyFailure) -> PlaintextOutcome {
        guard let keyMaterial, let helloI else { throw NearbyFailure(.cancelled) }
        guard suite == helloI.suite else { throw NearbyFailure(.suiteMismatch) }
        let version = min(helloI.maxVersion, maxVersion)
        guard version >= NearbyProtocol.minVersion else { throw NearbyFailure(.unsupportedVersion) }
        let secret = try NearbyCrypto.sharedSecret(privateKey: keyMaterial.privateKey, peerPublicKey: publicKey)
        let transcript = NearbyTranscriptModel(
            maxVersionI: helloI.maxVersion,
            maxVersionR: maxVersion,
            version: version,
            suiteI: helloI.suite,
            suiteR: suite,
            commitment: helloI.commitment,
            publicKeyI: keyMaterial.publicKey,
            nonceI: keyMaterial.nonce,
            nameI: helloI.name,
            publicKeyR: publicKey,
            nonceR: nonce,
            nameR: name
        )
        let reveal = NearbyHandshakeFrame.revealInitiator(publicKey: keyMaterial.publicKey, nonce: keyMaterial.nonce)
        let sas = establish(secret: secret, transcript: transcript, peerName: name)
        return .established(reply: reveal.encoded(), sas: sas)
    }

    /// R, steps 3–4: recompute C, agree, derive.
    private mutating func responderReceivedReveal(publicKey: Data, nonce: Data) throws(NearbyFailure) -> PlaintextOutcome {
        guard let keyMaterial, let helloI else { throw NearbyFailure(.cancelled) }
        let expected = NearbyCrypto.commitment(
            maxVersion: helloI.maxVersion,
            suite: helloI.suite,
            publicKey: publicKey,
            nonce: nonce,
            labels: purpose.labels
        )
        let matches = expected.withUnsafeBytes { lhs in
            helloI.commitment.withUnsafeBytes { rhs in SecretBytes.constantTimeEquals(lhs, rhs) }
        }
        guard matches else { throw NearbyFailure(.commitmentMismatch) }
        let secret = try NearbyCrypto.sharedSecret(privateKey: keyMaterial.privateKey, peerPublicKey: publicKey)
        let transcript = NearbyTranscriptModel(
            maxVersionI: helloI.maxVersion,
            maxVersionR: NearbyProtocol.maxVersion,
            version: min(helloI.maxVersion, NearbyProtocol.maxVersion),
            suiteI: helloI.suite,
            suiteR: NearbyProtocol.suite,
            commitment: helloI.commitment,
            publicKeyI: publicKey,
            nonceI: nonce,
            nameI: helloI.name,
            publicKeyR: keyMaterial.publicKey,
            nonceR: keyMaterial.nonce,
            nameR: localName
        )
        let sas = establish(secret: secret, transcript: transcript, peerName: helloI.name)
        return .established(reply: nil, sas: sas)
    }

    private mutating func establish(
        secret: SharedSecret,
        transcript: NearbyTranscriptModel,
        peerName: Data
    ) -> NearbySASModel {
        let labels = purpose.labels
        let derived = NearbyCrypto.deriveSession(
            sharedSecret: secret,
            transcriptHash: NearbyCrypto.transcriptHash(transcript, labels: labels),
            labels: labels
        )
        keys = derived
        keyMaterial = nil
        let model = NearbySASModel(value: derived.sasValue, peerName: Self.displayName(peerName))
        sas = model
        return model
    }

    private static func displayName(_ wireName: Data) -> String {
        DisplayNameSanitizer.sanitize(String(decoding: wireName, as: UTF8.self))
    }

    // MARK: - Code confirmation

    /// "Codes match": the encrypted CONFIRM frame. Only once, and only after keys exist.
    mutating func confirm() throws(NearbyFailure) -> Data {
        guard keys != nil, !localConfirmed else { throw NearbyFailure(.unexpectedMessage) }
        localConfirmed = true
        return try seal(NearbyProtocol.confirmMessageType, NearbyProtocol.confirmBody)
    }

    /// The peer's CONFIRM body (already opened). A second CONFIRM is a protocol error.
    mutating func receiveConfirm(_ body: Data) throws(NearbyFailure) {
        guard body == NearbyProtocol.confirmBody, !remoteConfirmed else {
            throw NearbyFailure(.unexpectedMessage)
        }
        remoteConfirmed = true
    }

    // MARK: - Encrypted channel

    /// Seals one frame with this direction's key and the next sequence number.
    mutating func seal(_ type: UInt8, _ body: Data) throws(NearbyFailure) -> Data {
        guard let keys else { throw NearbyFailure(.unexpectedMessage) }
        let frame = try NearbyEncryptedFrame.seal(
            rawType: type,
            sequence: sendSequence,
            body: body,
            key: keys.sendingKey(for: role)
        )
        sendSequence += 1
        return frame
    }

    /// Splits `bytes` into frames of at most `maxChunk` plaintext bytes each, prefixing every
    /// chunk with `prefix` (empty for share). Chunks are wiped once sealed.
    mutating func sealChunks(
        _ type: UInt8,
        _ bytes: Data,
        prefix: Data = Data(),
        maxChunk: Int = NearbyProtocol.maxFramePlaintextBytes
    ) throws(NearbyFailure) -> [Data] {
        let chunkLimit = maxChunk - prefix.count
        guard chunkLimit > 0 else { throw NearbyFailure(.oversizeFrame) }
        var frames: [Data] = []
        var offset = 0
        repeat {
            let length = min(chunkLimit, bytes.count - offset)
            guard var slice = bytes.bytes(at: offset, length: length) else {
                throw NearbyFailure(.malformedFrame)
            }
            var chunk = prefix
            chunk.append(slice)
            defer {
                slice.wipe()
                chunk.wipe()
            }
            frames.append(try seal(type, chunk))
            offset += length
        } while offset < bytes.count
        return frames
    }

    /// Opens the peer's next frame and returns its authenticated type byte.
    mutating func open(_ frame: Data) throws(NearbyFailure) -> (type: UInt8, body: Data) {
        guard let keys else { throw NearbyFailure(.unexpectedMessage) }
        guard receiveSequence < Limits.maxNearbySequence else { throw NearbyFailure(.sequenceExhausted) }
        let opened = try NearbyEncryptedFrame.open(
            raw: frame,
            expectedSequence: receiveSequence,
            key: keys.receivingKey(for: role)
        )
        receiveSequence += 1
        return opened
    }

    /// After keys exist, a plaintext ABORT is accepted only until the first encrypted frame
    /// from the peer has arrived (the peer may not have keys yet). Returns its code, or nil when
    /// `frame` is not such an ABORT.
    func plaintextAbortCode(_ frame: Data) throws(NearbyFailure) -> NearbyAbortCode? {
        guard receiveSequence == 0, frame.first == NearbyMessageType.abort.rawValue else { return nil }
        guard case .abort(let code) = try NearbyHandshakeFrame.decode(frame) else { return nil }
        return NearbyAbortCode(rawValue: code) ?? .protocolError
    }

    /// The ABORT frame for a local reason: encrypted once keys exist, plaintext before, none
    /// before the handshake started.
    mutating func abortFrame(code: NearbyAbortCode) -> Data? {
        if keys != nil {
            return try? seal(NearbyMessageType.abort.rawValue, Data([code.rawValue]))
        }
        guard hasStarted else { return nil }
        return NearbyHandshakeFrame.abort(code: code.rawValue).encoded()
    }

    /// Drops every key and the handshake secrets. `SymmetricKey` storage is released (CryptoKit
    /// zeroes it on deallocation); there is no way to resume. The code stays readable.
    mutating func wipe() {
        keys = nil
        keyMaterial = nil
        helloI = nil
    }
}
