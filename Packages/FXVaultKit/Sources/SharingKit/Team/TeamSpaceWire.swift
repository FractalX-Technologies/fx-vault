import Foundation
import VaultCore

/// Bodies of the spaces service's requests (v0.6.0, S6; docs/SHARING-PROTOCOL.md §11).
enum TeamSpaceWire {
    /// `u16 count ‖ (spaceID(16) ‖ u64 version ‖ hash(32))*`.
    static func encode(_ heads: [SpaceHeadModel]) -> Data {
        var body = Data()
        body.appendBigEndian(UInt16(clamping: heads.count))
        for head in heads.prefix(SpaceProtocol.maxHeads) {
            body.append(contentsOf: head.spaceID.bytes)
            body.appendBigEndian(head.version)
            body.append(head.hash)
        }
        return body
    }

    static func decodeHeads(_ body: Data) throws(NearbyFailure) -> [SpaceHeadModel] {
        var reader = NearbyByteReader(body)
        let count = Int(try reader.uint16())
        guard count <= SpaceProtocol.maxHeads else { throw NearbyFailure(.oversizeFrame) }
        var heads: [SpaceHeadModel] = []
        var seen: Set<SpaceID> = []
        for _ in 0..<count {
            guard let spaceID = SpaceID(bytes: try reader.bytes(SpaceID.byteCount)) else { throw NearbyFailure(.malformedFrame) }
            let version = try reader.uint64()
            let hash = try reader.bytes(SpaceProtocol.hashBytes)
            guard version >= 1, seen.insert(spaceID).inserted else { throw NearbyFailure(.malformedFrame) }
            heads.append(SpaceHeadModel(spaceID: spaceID, version: version, hash: hash))
        }
        try reader.requireEnd()
        return heads
    }

    /// `spaceID(16) ‖ u64 version`.
    static func encodeFetch(_ spaceID: SpaceID, version: UInt64) -> Data {
        var body = Data(spaceID.bytes)
        body.appendBigEndian(version)
        return body
    }

    static func decodeFetch(_ body: Data) throws(NearbyFailure) -> (SpaceID, UInt64) {
        var reader = NearbyByteReader(body)
        guard let spaceID = SpaceID(bytes: try reader.bytes(SpaceID.byteCount)) else { throw NearbyFailure(.malformedFrame) }
        let version = try reader.uint64()
        try reader.requireEnd()
        guard version >= 1 else { throw NearbyFailure(.malformedFrame) }
        return (spaceID, version)
    }
}
