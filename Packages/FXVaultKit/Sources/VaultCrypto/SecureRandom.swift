import Foundation
import VaultCore

/// Cryptographically secure random bytes from the system CSPRNG (`arc4random_buf`), which on
/// Apple platforms is seeded by the kernel and cannot fail.
public enum SecureRandom {
    /// Fills `buffer` with random bytes.
    public static func fill(_ buffer: UnsafeMutableRawBufferPointer) {
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
        arc4random_buf(base, buffer.count)
    }

    /// `count` random bytes, for non-secret material such as salts, nonces and ids.
    public static func data(count: Int) -> Data {
        var data = Data(count: max(count, 0))
        data.withUnsafeMutableBytes { fill($0) }
        return data
    }

    /// `count` random bytes in a wipeable buffer, for secret material such as recovery keys.
    public static func secretBytes(count: Int) -> SecretBytes {
        let bytes = SecretBytes(count: count)
        bytes.withUnsafeMutableBytes { fill($0) }
        return bytes
    }
}
