import CryptoKit
import Foundation
import VaultCore

/// The 256-bit recovery key (D9, §5.3).
///
/// Text form: `key(32) ‖ SHA256("fxvault/v1/recovery-check" ‖ key)[0..<3]` = 35 bytes =
/// 56 Crockford Base32 characters, shown as 14 groups of 4. The 24-bit checksum catches typing
/// mistakes before the (cheap) unwrap is attempted. The key is never persisted; the material
/// lives in a ``SecretBytes`` buffer that the owner wipes with ``wipe()`` when done.
public struct RecoveryKey: Sendable {
    private let material: SecretBytes

    /// A new random recovery key.
    public static func generate() -> RecoveryKey {
        RecoveryKey(material: SecureRandom.secretBytes(count: Limits.recoveryKeyBytes))
    }

    /// Parses user input: any case, with or without `-` and whitespace, `I`/`L` read as `1` and
    /// `O` as `0`.
    ///
    /// - Throws: `VaultError.invalidRecoveryKey` for a wrong length, a character outside the
    ///   alphabet (including `U`) or a checksum mismatch.
    public init(parsing text: String) throws(VaultError) {
        guard
            let payload = CrockfordBase32.decode(text),
            payload.count == Self.payloadBytes
        else { throw .invalidRecoveryKey }
        defer { payload.wipe() }

        let key = payload.prefix(Limits.recoveryKeyBytes)
        let checksumMatches = payload.withUnsafeBytes { bytes in
            let stored = UnsafeRawBufferPointer(rebasing: bytes[Limits.recoveryKeyBytes...])
            return Self.checksum(of: key).withUnsafeBytes { computed in
                SecretBytes.constantTimeEquals(computed, stored)
            }
        }
        guard checksumMatches else {
            key.wipe()
            throw .invalidRecoveryKey
        }
        material = key
    }

    /// Wraps existing key material (exactly ``Limits/recoveryKeyBytes`` bytes). Internal so
    /// known-answer tests can use fixed material.
    init(material: SecretBytes) {
        precondition(material.count == Limits.recoveryKeyBytes, "recovery key material must be 32 bytes")
        self.material = material
    }

    // MARK: - Display

    /// The 56-character Crockford Base32 text without separators.
    ///
    /// The returned `String` cannot be wiped: build it only while the key is on screen.
    public var text: String {
        let payload = SecretBytes(count: Self.payloadBytes)
        defer { payload.wipe() }
        let checksum = Self.checksum(of: material)
        payload.withUnsafeMutableBytes { out in
            material.withUnsafeBytes { key in
                out.copyMemory(from: key)
            }
            checksum.withUnsafeBytes { check in
                UnsafeMutableRawBufferPointer(rebasing: out[Limits.recoveryKeyBytes...]).copyMemory(from: check)
            }
        }
        return CrockfordBase32.encode(payload)
    }

    /// The 14 groups of 4 characters, in order.
    public var groups: [String] {
        let characters = Array(text)
        return stride(from: 0, to: characters.count, by: Limits.recoveryKeyGroupSize).map { start in
            String(characters[start..<min(start + Limits.recoveryKeyGroupSize, characters.count)])
        }
    }

    /// The groups joined with `-`, for copying to a password manager.
    public var formatted: String {
        groups.joined(separator: String(Self.groupSeparator))
    }

    /// True when `input` (normalized like ``init(parsing:)``) equals group `index` (0-based), for
    /// the onboarding confirmation of 2 random groups (§5.3). False for an out-of-range index.
    public func matches(group input: String, at index: Int) -> Bool {
        let groups = groups
        guard groups.indices.contains(index), let normalized = CrockfordBase32.normalize(input) else { return false }
        return Data(normalized.utf8).withUnsafeBytes { lhs in
            Data(groups[index].utf8).withUnsafeBytes { rhs in
                SecretBytes.constantTimeEquals(lhs, rhs)
            }
        }
    }

    // MARK: - Lifetime

    /// Zeroes the key material. The key is unusable afterwards.
    public func wipe() {
        material.wipe()
    }

    /// Calls `body` with the 32 key bytes. Internal: only the key hierarchy reads them.
    func withUnsafeBytes<Result>(_ body: (UnsafeRawBufferPointer) -> Result) -> Result {
        material.withUnsafeBytes(body)
    }

    // MARK: - Private

    private static let payloadBytes = Limits.recoveryKeyBytes + Limits.recoveryChecksumBytes
    private static let groupSeparator: Character = "-"

    private static func checksum(of key: SecretBytes) -> Data {
        var hash = SHA256()
        hash.update(data: Data(CryptoDomain.recoveryCheckLabel.utf8))
        key.withUnsafeBytes { hash.update(bufferPointer: $0) }
        return Data(hash.finalize().prefix(Limits.recoveryChecksumBytes))
    }
}
