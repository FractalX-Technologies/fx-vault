import Foundation

/// Big-endian integer and length-prefix helpers for the `.fxvault` header and nearby frames.
extension Data {
    /// Appends `value` in big-endian byte order.
    mutating func appendBigEndian<Value: FixedWidthInteger>(_ value: Value) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    /// Appends a u32 big-endian length prefix followed by `bytes` (the transcript `LP()`).
    mutating func appendLengthPrefixed(_ bytes: some Collection<UInt8>) {
        appendBigEndian(UInt32(truncatingIfNeeded: bytes.count))
        append(contentsOf: bytes)
    }

    /// Reads a big-endian integer of `Value`'s width at `offset` (relative to `startIndex`).
    /// Returns nil when the bytes are not all present.
    func readBigEndian<Value: FixedWidthInteger>(
        _ type: Value.Type,
        at offset: Int
    ) -> Value? {
        let width = MemoryLayout<Value>.size
        guard offset >= 0, offset <= count - width else { return nil }
        let start = startIndex + offset
        return self[start..<(start + width)].reduce(Value.zero) { ($0 << 8) | Value($1) }
    }

    /// The bytes in `offset..<(offset + length)` (relative to `startIndex`) as a new `Data`
    /// with zero-based indices, or nil when out of range.
    func bytes(at offset: Int, length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset <= count - length else { return nil }
        let start = startIndex + offset
        return Data(self[start..<(start + length)])
    }

    /// Overwrites every byte with zero (best-effort wipe of a buffer that held plaintext).
    mutating func wipe() {
        resetBytes(in: startIndex..<endIndex)
    }
}
