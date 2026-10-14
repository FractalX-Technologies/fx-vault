import Foundation
import VaultCore

/// 4-byte big-endian length framing for the TCP transport (§9.4).
///
/// The length prefix is checked against ``maxFrameBytes`` before any frame bytes are
/// buffered, so a hostile prefix cannot make the receiver allocate. Zero-length frames are
/// rejected (no protocol frame is empty).
public struct NearbyLengthFramer: Sendable {
    /// Size of the length prefix.
    public static let prefixBytes = MemoryLayout<UInt32>.size

    public let maxFrameBytes: Int
    private var buffer = Data()

    public init(maxFrameBytes: Int = NearbyProtocol.maxTransportFrameBytes) {
        self.maxFrameBytes = maxFrameBytes
    }

    /// Bytes buffered but not yet returned as a frame.
    public var pendingByteCount: Int {
        buffer.count
    }

    /// `u32 BE length ‖ frame`.
    public func encode(_ frame: Data) throws(ShareError) -> Data {
        guard !frame.isEmpty else { throw .transport(.malformedFrame) }
        guard frame.count <= maxFrameBytes else { throw .transport(.oversizeFrame) }
        var data = Data(capacity: Self.prefixBytes + frame.count)
        data.appendBigEndian(UInt32(frame.count))
        data.append(frame)
        return data
    }

    /// Appends received bytes and returns every complete frame, in order. After a throw the
    /// stream is unusable: the transport must close.
    public mutating func append(_ bytes: Data) throws(ShareError) -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while let length = buffer.readBigEndian(UInt32.self, at: 0) {
            let frameLength = Int(length)
            guard frameLength > 0 else { throw .transport(.malformedFrame) }
            guard frameLength <= maxFrameBytes else { throw .transport(.oversizeFrame) }
            guard let frame = buffer.bytes(at: Self.prefixBytes, length: frameLength) else { break }
            frames.append(frame)
            buffer = Data(buffer.dropFirst(Self.prefixBytes + frameLength))
        }
        return frames
    }
}
