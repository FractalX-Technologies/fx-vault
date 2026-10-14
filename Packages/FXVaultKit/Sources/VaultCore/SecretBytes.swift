import Foundation

/// A heap buffer for plaintext secrets that is zeroed with `memset_s` when wiped or freed (§5.12).
///
/// - The bytes live in memory this class owns; they are never copied into a `String`, `Data` or
///   `Array` unless a caller asks for one explicitly (``utf8String()``), and such a copy
///   cannot be wiped.
/// - `description`, `debugDescription` and `customMirror` never show the bytes.
/// - Equality is constant-time over the contents (lengths are compared first and are not secret).
/// - Not `Hashable` and not `Codable`, so a value cannot end up in a hash table, a log or JSON by
///   accident.
///
/// Thread safety: every access to the buffer holds an internal recursive lock, so ``wipe()``
/// cannot race a reader. That makes the class safe to share across concurrency domains, hence
/// `@unchecked Sendable`. Bodies passed to ``withUnsafeBytes(_:)`` run while the lock is held: keep
/// them short and never let the pointer escape.
public final class SecretBytes: @unchecked Sendable {
    private let storage: UnsafeMutableRawBufferPointer
    private let lock = NSRecursiveLock()
    private var wiped = false

    /// Number of bytes. Unchanged by ``wipe()`` (the bytes become zero).
    public let count: Int

    // MARK: - Creating

    /// A zero-filled buffer of `count` bytes, for callers that write into it
    /// (``withUnsafeMutableBytes(_:)``), such as a KDF output.
    public init(count: Int) {
        let size = max(count, 0)
        self.count = size
        storage = Self.allocate(byteCount: size)
        storage.initializeMemory(as: UInt8.self, repeating: 0)
    }

    /// Copies `bytes` (`Data`, `[UInt8]`, `String.UTF8View`, `UnsafeRawBufferPointer`, ...).
    /// The source itself is not wiped.
    public init(copying bytes: some Collection<UInt8>) {
        let size = bytes.count
        count = size
        storage = Self.allocate(byteCount: size)
        storage.initializeMemory(as: UInt8.self, repeating: 0)
        UnsafeMutableRawBufferPointer(rebasing: storage[0..<size]).copyBytes(from: bytes)
    }

    /// Copies `data`. The caller's `Data` is not wiped; prefer ``init(wipingSource:)``.
    public convenience init(_ data: Data) {
        self.init(copying: data)
    }

    /// Copies `data`, then overwrites `data` with zeros (for example a process stdout buffer).
    public convenience init(wipingSource data: inout Data) {
        self.init(copying: data)
        data.resetBytes(in: data.startIndex..<data.endIndex)
    }

    /// Copies the UTF-8 bytes of `string`. The `String` itself cannot be wiped (§5.14).
    public convenience init(utf8 string: String) {
        self.init(copying: string.utf8)
    }

    deinit {
        Self.zero(storage)
        storage.deallocate()
    }

    // MARK: - Reading

    /// True when the buffer holds no bytes.
    public var isEmpty: Bool {
        count == 0
    }

    /// True after ``wipe()``.
    public var isWiped: Bool {
        lock.withLock { wiped }
    }

    /// Calls `body` with the bytes. The pointer is valid only inside `body`.
    public func withUnsafeBytes<Result, Failure: Error>(
        _ body: (UnsafeRawBufferPointer) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(UnsafeRawBufferPointer(rebasing: storage[0..<count]))
    }

    /// Calls `body` with writable bytes (for example a KDF output). The pointer is valid only
    /// inside `body`.
    public func withUnsafeMutableBytes<Result, Failure: Error>(
        _ body: (UnsafeMutableRawBufferPointer) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(UnsafeMutableRawBufferPointer(rebasing: storage[0..<count]))
    }

    /// A new buffer with the same bytes. Both must be wiped independently.
    public func copy() -> SecretBytes {
        withUnsafeBytes { SecretBytes(copying: $0) }
    }

    /// A new buffer holding the first `length` bytes (clamped to ``count``).
    public func prefix(_ length: Int) -> SecretBytes {
        withUnsafeBytes { bytes in
            let end = min(max(length, 0), bytes.count)
            return SecretBytes(copying: UnsafeRawBufferPointer(rebasing: bytes[0..<end]))
        }
    }

    /// Decodes the bytes as UTF-8, or nil if they are not valid UTF-8.
    ///
    /// The returned `String` is a copy that cannot be wiped. Only for the one value being
    /// revealed or edited (§5.12).
    public func utf8String() -> String? {
        withUnsafeBytes { bytes in
            String(bytes: bytes, encoding: .utf8)
        }
    }

    // MARK: - Wiping

    /// Overwrites every byte with zero using `memset_s`, which the compiler may not elide.
    /// Idempotent. The buffer keeps its ``count``.
    public func wipe() {
        lock.withLock {
            Self.zero(storage)
            wiped = true
        }
    }

    // MARK: - Constant-time comparison

    /// Compares two byte buffers in time that depends only on their lengths.
    public static func constantTimeEquals(
        _ lhs: UnsafeRawBufferPointer,
        _ rhs: UnsafeRawBufferPointer
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<lhs.count {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    /// Compares the contents with `other` in constant time.
    public func constantTimeEquals(_ other: some ContiguousBytes) -> Bool {
        withUnsafeBytes { mine in
            other.withUnsafeBytes { theirs in
                Self.constantTimeEquals(mine, theirs)
            }
        }
    }

    // MARK: - Private

    private static func allocate(byteCount: Int) -> UnsafeMutableRawBufferPointer {
        // Allocate at least one byte so `baseAddress` is never nil.
        UnsafeMutableRawBufferPointer.allocate(
            byteCount: max(byteCount, 1),
            alignment: MemoryLayout<UInt8>.alignment
        )
    }

    private static func zero(_ buffer: UnsafeMutableRawBufferPointer) {
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
        _ = memset_s(base, buffer.count, 0, buffer.count)
    }
}

extension SecretBytes: Equatable {
    /// Constant-time comparison of the contents. Locks are taken in a fixed order, so `a == b`
    /// and `b == a` running concurrently cannot deadlock.
    public static func == (lhs: SecretBytes, rhs: SecretBytes) -> Bool {
        if lhs === rhs { return true }
        let lhsFirst = ObjectIdentifier(lhs) < ObjectIdentifier(rhs)
        let (first, second) = lhsFirst ? (lhs, rhs) : (rhs, lhs)
        return first.withUnsafeBytes { firstBytes in
            second.withUnsafeBytes { secondBytes in
                constantTimeEquals(firstBytes, secondBytes)
            }
        }
    }
}

extension SecretBytes: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The text every textual representation uses.
    public static let redacted = "<redacted>"

    public var description: String {
        Self.redacted
    }

    public var debugDescription: String {
        Self.redacted
    }

    public var customMirror: Mirror {
        Mirror(self, children: [], displayStyle: .class)
    }
}
