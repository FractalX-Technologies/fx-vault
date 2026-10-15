import CryptoKit
import Foundation
import SharingKit
import VaultCore
import VaultCrypto

/// SharingKit's ``KeyDeriving`` backed by VaultCrypto's Argon2id v1.3 (§4.2, §9.1).
///
/// SharingKit does not link libsodium; VaultData injects this into `FxVaultFileCodec(deriver:)`.
/// The KDF runs off the caller's actor (`@concurrent`). The codec checks every header bound
/// before calling it; this adapter additionally refuses a parallelism other than 1 (libsodium
/// only implements `p = 1`, so any other value would silently derive a different key) and
/// converts the header's KiB to bytes.
public struct Argon2idSharingDeriver: KeyDeriving {
    /// The only Argon2id parallelism libsodium implements.
    static let supportedParallelism: UInt8 = 1

    public init() {}

    /// - Throws: `CancellationError` when the task is cancelled before or after the KDF,
    ///   `CryptoError.invalidKDFInput` for unsupported parameters, `CryptoError.kdfFailed` when
    ///   libsodium fails.
    @concurrent
    public func deriveKey(
        passphrase: SecretBytes,
        parameters: KeyDerivationParametersModel
    ) async throws -> SecretBytes {
        try Task.checkCancellation()
        guard parameters.parallelism == Self.supportedParallelism else { throw CryptoError.invalidKDFInput }
        let memLimitBytes = UInt64(parameters.memLimitKiB) * UInt64(Limits.bytesPerKiB)
        let key = try Argon2id.deriveKey(
            password: passphrase,
            salt: Data(parameters.salt),
            parameters: KDFParameters(opsLimit: parameters.opsLimit, memLimitBytes: memLimitBytes)
        )
        try Task.checkCancellation()
        return key.withUnsafeBytes { SecretBytes(copying: $0) }
    }
}
