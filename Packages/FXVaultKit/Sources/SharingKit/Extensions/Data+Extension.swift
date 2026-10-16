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

    /// Lowercase hex (teammate ids and pseudonyms, v0.5.0).
    var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Parses lowercase or uppercase hex; nil for an odd length or another character.
    init?(hexEncoded text: String) {
        let digits = Array(text.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(capacity: digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = Self.nibble(digits[index]), let low = Self.nibble(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        self = bytes
    }

    private static func nibble(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
