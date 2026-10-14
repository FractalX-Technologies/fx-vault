import VaultCore

/// Parameters for deriving a `.fxvault` file key (§9.1).
public struct KeyDerivationParametersModel: Sendable, Hashable {
    /// Argon2id `t`.
    public var opsLimit: UInt32
    /// Argon2id `m`, in KiB.
    public var memLimitKiB: UInt32
    /// Argon2id `p` (always 1 in v1).
    public var parallelism: UInt8
    /// 16 random bytes from the header.
    public var salt: [UInt8]

    public init(opsLimit: UInt32, memLimitKiB: UInt32, parallelism: UInt8, salt: [UInt8]) {
        self.opsLimit = opsLimit
        self.memLimitKiB = memLimitKiB
        self.parallelism = parallelism
        self.salt = salt
    }
}

/// Derives the 32-byte `.fxvault` file key from the normalized passphrase.
///
/// SharingKit does not link libsodium: VaultData adapts VaultCrypto's Argon2id v1.3 to this
/// protocol (§4.2), and should run it off the caller's executor (`@concurrent`). Tests inject
/// fakes and spies. ``FxVaultFileCodec`` checks every header bound **before** calling it.
public protocol KeyDeriving: Sendable {
    /// Returns exactly ``Limits/dekBytes`` bytes. The caller wipes the returned buffer.
    /// Throws `CancellationError` when the task is cancelled.
    func deriveKey(
        passphrase: SecretBytes,
        parameters: KeyDerivationParametersModel
    ) async throws -> SecretBytes
}
