import CryptoKit
import Foundation
import VaultCore

/// The encrypted channel every nearby protocol ends in (§9.4 step 6): one key per direction and
/// exact per-direction sequence numbers in the ``NearbyEncryptedFrame`` layout. Share and chat
/// reach it through the commit-reveal handshake (``NearbyKeyExchange``); teammates reach it
/// through the paired handshake (``TeamHandshake``, v0.5.0).
struct NearbyChannel: Sendable {
    let role: NearbyRole
    private let keys: NearbySessionKeys
    private var sendSequence: UInt64 = 0
    private var receiveSequence: UInt64 = 0

    init(role: NearbyRole, keys: NearbySessionKeys) {
        self.role = role
        self.keys = keys
    }

    /// True once the peer's first encrypted frame was opened.
    var hasReceived: Bool {
        receiveSequence > 0
    }

    /// Seals one frame with this direction's key and the next sequence number.
    mutating func seal(_ type: UInt8, _ body: Data) throws(NearbyFailure) -> Data {
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
    /// chunk with `prefix`. Chunks are wiped once sealed.
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
        guard receiveSequence < Limits.maxNearbySequence else { throw NearbyFailure(.sequenceExhausted) }
        let opened = try NearbyEncryptedFrame.open(
            raw: frame,
            expectedSequence: receiveSequence,
            key: keys.receivingKey(for: role)
        )
        receiveSequence += 1
        return opened
    }
}
