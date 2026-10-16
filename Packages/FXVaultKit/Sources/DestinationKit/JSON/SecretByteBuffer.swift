import Darwin
import Foundation
import VaultCore

/// A growable heap buffer for bytes that may hold values: request bodies being built, response
/// bodies being received, unescaped JSON strings (v0.8.0).
///
/// When it grows, the old storage is zeroed with `memset_s` before it is freed; ``wipe()`` and
/// `deinit` zero the rest. ``makeSecretBytes()`` hands the bytes over as `SecretBytes` and wipes
/// the buffer. Not thread-safe: use one buffer inside one task.
final class SecretByteBuffer {
    private static let defaultCapacity = 256
    private static let growthFactor = 2

    private var storage: UnsafeMutableRawBufferPointer
    /// Bytes written so far.
    private(set) var count = 0

    init(capacity: Int = SecretByteBuffer.defaultCapacity) {
        storage = Self.allocate(max(capacity, 1))
    }

    deinit {
        Self.zero(storage)
        storage.deallocate()
    }

    func append(_ byte: UInt8) {
        reserve(1)
        storage[count] = byte
        count += 1
    }

    func append(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        reserve(bytes.count)
        UnsafeMutableRawBufferPointer(rebasing: storage[count..<(count + bytes.count)]).copyMemory(from: bytes)
        count += bytes.count
    }

    /// Appends the UTF-8 bytes of `text` (JSON punctuation, keys, non-secret strings).
    func append(utf8 text: String) {
        for byte in text.utf8 {
            append(byte)
        }
    }

    /// Calls `body` with the bytes written so far.
    func withUnsafeBytes<Result, Failure: Error>(
        _ body: (UnsafeRawBufferPointer) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try body(UnsafeRawBufferPointer(rebasing: storage[0..<count]))
    }

    /// The bytes as a new `SecretBytes`; the buffer is wiped and empty afterwards.
    func makeSecretBytes() -> SecretBytes {
        let bytes = withUnsafeBytes { SecretBytes(copying: $0) }
        wipe()
        return bytes
    }

    /// Zeroes every byte and empties the buffer (the capacity stays).
    func wipe() {
        Self.zero(storage)
        count = 0
    }

    private func reserve(_ extra: Int) {
        let (needed, overflow) = count.addingReportingOverflow(extra)
        precondition(!overflow, "SecretByteBuffer size overflow")
        guard needed > storage.count else { return }
        let (doubled, doubleOverflow) = storage.count.multipliedReportingOverflow(by: Self.growthFactor)
        let capacity = doubleOverflow ? needed : max(needed, doubled)
        let grown = Self.allocate(capacity)
        UnsafeMutableRawBufferPointer(rebasing: grown[0..<count])
            .copyMemory(from: UnsafeRawBufferPointer(rebasing: storage[0..<count]))
        Self.zero(storage)
        storage.deallocate()
        storage = grown
    }

    private static func allocate(_ capacity: Int) -> UnsafeMutableRawBufferPointer {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity, alignment: MemoryLayout<UInt8>.alignment)
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        return buffer
    }

    private static func zero(_ buffer: UnsafeMutableRawBufferPointer) {
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
        _ = memset_s(base, buffer.count, 0, buffer.count)
    }
}

/// Byte-level UTF-8 checks (Unicode Table 3-7, well-formed byte sequences), so a value can be
/// validated without becoming a `String`.
enum UTF8Validation {
    private static let asciiLimit: UInt8 = 0x80
    private static let continuationRange: ClosedRange<UInt8> = 0x80...0xBF

    /// The length of the well-formed sequence starting at `index`, or nil (overlong forms,
    /// surrogates, code points above U+10FFFF, truncated sequences).
    static func sequenceLength(in bytes: UnsafeRawBufferPointer, at index: Int) -> Int? {
        guard index < bytes.count else { return nil }
        let lead = bytes[index]
        if lead < asciiLimit { return 1 }
        let second: ClosedRange<UInt8>
        let length: Int
        switch lead {
        case 0xC2...0xDF: second = continuationRange; length = 2
        case 0xE0: second = 0xA0...0xBF; length = 3
        case 0xE1...0xEC, 0xEE...0xEF: second = continuationRange; length = 3
        case 0xED: second = 0x80...0x9F; length = 3
        case 0xF0: second = 0x90...0xBF; length = 4
        case 0xF1...0xF3: second = continuationRange; length = 4
        case 0xF4: second = 0x80...0x8F; length = 4
        default: return nil
        }
        guard index + length <= bytes.count, second.contains(bytes[index + 1]) else { return nil }
        for offset in 2..<length where !continuationRange.contains(bytes[index + offset]) {
            return nil
        }
        return length
    }

    /// True when every byte belongs to a well-formed UTF-8 sequence.
    static func isValid(_ bytes: UnsafeRawBufferPointer) -> Bool {
        var index = 0
        while index < bytes.count {
            guard let length = sequenceLength(in: bytes, at: index) else { return false }
            index += length
        }
        return true
    }
}
