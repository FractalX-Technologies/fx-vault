import CryptoKit
import Foundation
import VaultCore

/// Plaintext frames sent before the session keys exist (§9.4 steps 1–3, plaintext ABORT).
///
/// - HELLO_I `0x01`: `maxVerI ‖ suiteI ‖ C(32) ‖ u16 len ‖ nameI`
/// - HELLO_R `0x02`: `maxVerR ‖ suiteR ‖ pkR(32) ‖ nR(32) ‖ u16 len ‖ nameR`
/// - REVEAL_I `0x03`: `pkI(32) ‖ nI(32)`
/// - ABORT `0x7F`: `reason(1)`
///
/// Names are sanitized NFC UTF-8, at most ``Limits/maxDisplayNameBytes``. Frames longer than
/// ``Limits/maxNearbyHandshakeFrameBytes`` or with trailing bytes are rejected.
enum NearbyHandshakeFrame: Sendable, Hashable {
    case helloInitiator(maxVersion: UInt8, suite: UInt8, commitment: Data, name: Data)
    case helloResponder(maxVersion: UInt8, suite: UInt8, publicKey: Data, nonce: Data, name: Data)
    case revealInitiator(publicKey: Data, nonce: Data)
    case abort(code: UInt8)

    func encoded() -> Data {
        var data = Data()
        switch self {
        case .helloInitiator(let maxVersion, let suite, let commitment, let name):
            data.append(NearbyMessageType.helloInitiator.rawValue)
            data.append(maxVersion)
            data.append(suite)
            data.append(commitment)
            data.appendBigEndian(UInt16(truncatingIfNeeded: name.count))
            data.append(name)
        case .helloResponder(let maxVersion, let suite, let publicKey, let nonce, let name):
            data.append(NearbyMessageType.helloResponder.rawValue)
            data.append(maxVersion)
            data.append(suite)
            data.append(publicKey)
            data.append(nonce)
            data.appendBigEndian(UInt16(truncatingIfNeeded: name.count))
            data.append(name)
        case .revealInitiator(let publicKey, let nonce):
            data.append(NearbyMessageType.revealInitiator.rawValue)
            data.append(publicKey)
            data.append(nonce)
        case .abort(let code):
            data.append(NearbyMessageType.abort.rawValue)
            data.append(code)
        }
        return data
    }

    static func decode(_ frame: Data) throws(NearbyFailure) -> NearbyHandshakeFrame {
        guard frame.count <= Limits.maxNearbyHandshakeFrameBytes else {
            throw NearbyFailure(.oversizeFrame)
        }
        var reader = NearbyByteReader(frame)
        let rawType = try reader.byte()
        guard let type = NearbyMessageType(rawValue: rawType) else {
            throw NearbyFailure(.unexpectedMessage)
        }
        let decoded: NearbyHandshakeFrame
        switch type {
        case .helloInitiator:
            let maxVersion = try reader.byte()
            let suite = try reader.byte()
            let commitment = try reader.bytes(NearbyProtocol.hashBytes)
            let name = try readName(&reader)
            decoded = .helloInitiator(maxVersion: maxVersion, suite: suite, commitment: commitment, name: name)
        case .helloResponder:
            let maxVersion = try reader.byte()
            let suite = try reader.byte()
            let publicKey = try reader.bytes(NearbyProtocol.publicKeyBytes)
            let nonce = try reader.bytes(NearbyProtocol.nonceBytes)
            let name = try readName(&reader)
            decoded = .helloResponder(
                maxVersion: maxVersion,
                suite: suite,
                publicKey: publicKey,
                nonce: nonce,
                name: name
            )
        case .revealInitiator:
            let publicKey = try reader.bytes(NearbyProtocol.publicKeyBytes)
            let nonce = try reader.bytes(NearbyProtocol.nonceBytes)
            decoded = .revealInitiator(publicKey: publicKey, nonce: nonce)
        case .abort:
            decoded = .abort(code: try reader.byte())
        default:
            throw NearbyFailure(.unexpectedMessage)
        }
        try reader.requireEnd()
        return decoded
    }

    private static func readName(_ reader: inout NearbyByteReader) throws(NearbyFailure) -> Data {
        let length = Int(try reader.uint16())
        guard length <= Limits.maxDisplayNameBytes else { throw NearbyFailure(.malformedFrame) }
        let name = try reader.bytes(length)
        guard String(data: name, encoding: .utf8) != nil else { throw NearbyFailure(.malformedFrame) }
        return name
    }
}

/// Encrypted frames (§9.4): `[ver][type][seq:8 BE][ciphertext][tag:16]`, AAD = the first 10
/// bytes, nonce = `0^4 ‖ seq`, one key per direction, exact sequence per direction. The same
/// layout carries share (``NearbyMessageType``) and chat (``NearbyChatMessageType``) frames; the
/// keys are domain-separated by purpose, so a frame never opens under the other purpose.
enum NearbyEncryptedFrame {
    /// Seals `body` as a share frame of `type` with sequence number `sequence`.
    static func seal(
        type: NearbyMessageType,
        sequence: UInt64,
        body: Data,
        key: SymmetricKey
    ) throws(NearbyFailure) -> Data {
        try seal(rawType: type.rawValue, sequence: sequence, body: body, key: key)
    }

    /// Seals `body` as a frame whose type byte is `rawType`.
    static func seal(
        rawType: UInt8,
        sequence: UInt64,
        body: Data,
        key: SymmetricKey
    ) throws(NearbyFailure) -> Data {
        guard sequence < Limits.maxNearbySequence else { throw NearbyFailure(.sequenceExhausted) }
        guard body.count <= NearbyProtocol.maxFramePlaintextBytes else {
            throw NearbyFailure(.oversizeFrame)
        }
        let header = header(type: rawType, sequence: sequence)
        do {
            let box = try AES.GCM.seal(body, using: key, nonce: try nonce(sequence), authenticating: header)
            return header + box.ciphertext + box.tag
        } catch {
            throw NearbyFailure(.decryptionFailed)
        }
    }

    /// Opens a share frame that must carry `expectedSequence`. Checks, in order: size, version,
    /// sequence, authentication, then the (authenticated) type.
    static func open(
        _ frame: Data,
        expectedSequence: UInt64,
        key: SymmetricKey
    ) throws(NearbyFailure) -> (type: NearbyMessageType, body: Data) {
        let (rawType, body) = try open(raw: frame, expectedSequence: expectedSequence, key: key)
        guard let type = NearbyMessageType(rawValue: rawType) else {
            throw NearbyFailure(.unexpectedMessage)
        }
        return (type, body)
    }

    /// Opens a frame and returns its authenticated type byte; the caller maps it to its own
    /// message types (an unknown type is `.unexpectedMessage`).
    static func open(
        raw frame: Data,
        expectedSequence: UInt64,
        key: SymmetricKey
    ) throws(NearbyFailure) -> (type: UInt8, body: Data) {
        guard frame.count <= Limits.maxNearbyEncryptedFrameBytes else {
            throw NearbyFailure(.oversizeFrame)
        }
        let minimum = NearbyProtocol.encryptedHeaderBytes + Limits.gcmTagBytes
        guard frame.count >= minimum,
              let header = frame.bytes(at: 0, length: NearbyProtocol.encryptedHeaderBytes),
              let sequence = frame.readBigEndian(UInt64.self, at: Offset.sequence),
              let ciphertext = frame.bytes(
                  at: NearbyProtocol.encryptedHeaderBytes,
                  length: frame.count - minimum
              ),
              let tag = frame.bytes(at: frame.count - Limits.gcmTagBytes, length: Limits.gcmTagBytes)
        else { throw NearbyFailure(.malformedFrame) }
        guard header[Offset.version] == NearbyProtocol.maxVersion else {
            throw NearbyFailure(.unsupportedVersion)
        }
        guard sequence == expectedSequence else { throw NearbyFailure(.sequenceMismatch) }
        let body: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: try nonce(sequence), ciphertext: ciphertext, tag: tag)
            body = try AES.GCM.open(box, using: key, authenticating: header)
        } catch {
            throw NearbyFailure(.decryptionFailed)
        }
        return (header[Offset.type], body)
    }

    private enum Offset {
        static let version = 0
        static let type = 1
        static let sequence = 2
    }

    private static func header(type: UInt8, sequence: UInt64) -> Data {
        var header = Data([NearbyProtocol.maxVersion, type])
        header.appendBigEndian(sequence)
        return header
    }

    private static func nonce(_ sequence: UInt64) throws -> AES.GCM.Nonce {
        var bytes = Data(count: NearbyProtocol.nonceZeroPrefixBytes)
        bytes.appendBigEndian(sequence)
        return try AES.GCM.Nonce(data: bytes)
    }
}

/// Bodies of encrypted messages.
enum NearbyMessageBody {
    private static let falseByte: UInt8 = 0
    private static let trueByte: UInt8 = 1

    // MARK: DECISION: accept(1) ‖ u32 count ‖ count × 16-byte entry ids

    static func decision(_ decision: NearbyDecisionModel) -> Data {
        var data = Data([decision.accept ? trueByte : falseByte])
        let ids = decision.itemIDs.sorted()
        data.appendBigEndian(UInt32(truncatingIfNeeded: ids.count))
        for id in ids {
            data.append(contentsOf: id.bytes)
        }
        return data
    }

    static func decodeDecision(_ body: Data) throws(NearbyFailure) -> NearbyDecisionModel {
        var reader = NearbyByteReader(body)
        let accept = try boolean(&reader)
        let count = Int(try reader.uint32())
        guard count <= maxDecisionIDs, accept || count == 0 else { throw NearbyFailure(.malformedFrame) }
        var ids = Set<ShareEntryID>()
        for _ in 0..<count {
            guard let id = ShareEntryID(bytes: try reader.bytes(ShareEntryID.byteCount)),
                  ids.insert(id).inserted
            else { throw NearbyFailure(.malformedFrame) }
        }
        try reader.requireEnd()
        guard !accept || !ids.isEmpty else { throw NearbyFailure(.malformedFrame) }
        return NearbyDecisionModel(accept: accept, itemIDs: ids)
    }

    /// Most ids one DECISION frame can carry.
    static let maxDecisionIDs =
        (NearbyProtocol.maxFramePlaintextBytes - 1 - MemoryLayout<UInt32>.size) / ShareEntryID.byteCount

    // MARK: PAYLOAD_END: u64 totalLength ‖ SHA256(payload)

    static func payloadEnd(length: UInt64, digest: Data) -> Data {
        var data = Data()
        data.appendBigEndian(length)
        data.append(digest)
        return data
    }

    static func decodePayloadEnd(_ body: Data) throws(NearbyFailure) -> (length: UInt64, digest: Data) {
        var reader = NearbyByteReader(body)
        let length = try reader.uint64()
        let digest = try reader.bytes(NearbyProtocol.hashBytes)
        try reader.requireEnd()
        return (length, digest)
    }

    // MARK: RESULT: ok(1)

    static func result(ok: Bool) -> Data {
        Data([ok ? trueByte : falseByte])
    }

    static func decodeResult(_ body: Data) throws(NearbyFailure) -> Bool {
        var reader = NearbyByteReader(body)
        let ok = try boolean(&reader)
        try reader.requireEnd()
        return ok
    }

    // MARK: MANIFEST: first frame u32 totalLength ‖ bytes, following frames bytes only

    static func decodeManifestLength(_ body: Data) throws(NearbyFailure) -> (length: Int, rest: Data) {
        var reader = NearbyByteReader(body)
        let length = Int(try reader.uint32())
        return (length, reader.remaining())
    }

    // MARK: ABORT: code(1)

    static func decodeAbort(_ body: Data) throws(NearbyFailure) -> NearbyAbortCode {
        var reader = NearbyByteReader(body)
        let code = try reader.byte()
        try reader.requireEnd()
        return NearbyAbortCode(rawValue: code) ?? .protocolError
    }

    private static func boolean(_ reader: inout NearbyByteReader) throws(NearbyFailure) -> Bool {
        switch try reader.byte() {
        case falseByte: return false
        case trueByte: return true
        default: throw NearbyFailure(.malformedFrame)
        }
    }
}

/// A bounds-checked cursor over a frame. Every overrun is `.malformedFrame`.
struct NearbyByteReader {
    private var data: Data
    private var offset = 0

    init(_ data: Data) {
        self.data = Data(data)
    }

    mutating func byte() throws(NearbyFailure) -> UInt8 {
        try integer(UInt8.self)
    }

    mutating func uint16() throws(NearbyFailure) -> UInt16 {
        try integer(UInt16.self)
    }

    mutating func uint32() throws(NearbyFailure) -> UInt32 {
        try integer(UInt32.self)
    }

    mutating func uint64() throws(NearbyFailure) -> UInt64 {
        try integer(UInt64.self)
    }

    mutating func bytes(_ length: Int) throws(NearbyFailure) -> Data {
        guard let value = data.bytes(at: offset, length: length) else {
            throw NearbyFailure(.malformedFrame)
        }
        offset += length
        return value
    }

    func remaining() -> Data {
        data.bytes(at: offset, length: data.count - offset) ?? Data()
    }

    func requireEnd() throws(NearbyFailure) {
        guard offset == data.count else { throw NearbyFailure(.malformedFrame) }
    }

    /// Zeroes the reader's copy of the body (a body that held plaintext secret bytes).
    mutating func wipe() {
        data.wipe()
    }

    private mutating func integer<Value: FixedWidthInteger>(_ type: Value.Type) throws(NearbyFailure) -> Value {
        guard let value = data.readBigEndian(type, at: offset) else { throw NearbyFailure(.malformedFrame) }
        offset += MemoryLayout<Value>.size
        return value
    }
}
