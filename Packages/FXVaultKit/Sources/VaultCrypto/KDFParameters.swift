import VaultCore

/// The key-derivation function of a `key_wraps` row (`kdf_alg`, §6).
public enum KDFAlgorithm: UInt8, Sendable, Hashable, CaseIterable {
    /// Argon2id v1.3 over the NFC master password (method `password`).
    case argon2id13 = 1
    /// HKDF-SHA256 over the recovery key (method `recovery`).
    case hkdfSHA256 = 2
}

/// Argon2id cost parameters (D8). The salt is stored separately and is always
/// ``Limits/kdfSaltBytes`` long.
public struct KDFParameters: Sendable, Hashable {
    /// Argon2id passes (`t`, libsodium `opslimit`).
    public let opsLimit: UInt32
    /// Argon2id memory in bytes (libsodium `memlimit`; Argon2 itself works in KiB).
    public let memLimitBytes: UInt64

    public init(opsLimit: UInt32, memLimitBytes: UInt64) {
        self.opsLimit = opsLimit
        self.memLimitBytes = memLimitBytes
    }

    /// Production cost: 3 passes, 256 MiB (libsodium "moderate", D8).
    public static let moderate = KDFParameters(
        opsLimit: UInt32(Limits.passwordKDFOpsLimit),
        memLimitBytes: UInt64(Limits.passwordKDFMemoryBytes)
    )

    /// Fast cost for unit tests and previews only: 1 pass, 8 MiB (§12.1). Accepted only by
    /// ``KDFBounds/testing``, never by ``KDFBounds/password``.
    public static let testing = KDFParameters(opsLimit: testingOpsLimit, memLimitBytes: testingMemoryBytes)

    /// Passes of ``testing`` (libsodium's minimum).
    public static let testingOpsLimit = UInt32(Limits.passwordKDFTestingOpsLimit)
    /// Memory of ``testing`` in bytes (8 MiB).
    public static let testingMemoryBytes = UInt64(Limits.passwordKDFTestingMemoryBytes)
}

/// Accepted ranges for stored Argon2id parameters, checked **before** the KDF runs (§5.2), so a
/// tampered row can neither weaken the KDF nor make unlock allocate gigabytes.
public struct KDFBounds: Sendable, Hashable {
    /// Accepted Argon2id passes.
    public let opsLimit: ClosedRange<UInt32>
    /// Accepted Argon2id memory in bytes.
    public let memLimitBytes: ClosedRange<UInt64>
    /// Required salt length in bytes.
    public let saltBytes: Int

    public init(opsLimit: ClosedRange<UInt32>, memLimitBytes: ClosedRange<UInt64>, saltBytes: Int) {
        self.opsLimit = opsLimit
        self.memLimitBytes = memLimitBytes
        self.saltBytes = saltBytes
    }

    /// Production bounds of the master-password wrap: 2...10 passes, 64 MiB...1 GiB, 16-byte salt.
    public static let password = KDFBounds(
        opsLimit: UInt32(Limits.passwordKDFOpsLimitMin)...UInt32(Limits.passwordKDFOpsLimitMax),
        memLimitBytes: UInt64(Limits.passwordKDFMemoryBytesMin)...UInt64(Limits.passwordKDFMemoryBytesMax),
        saltBytes: Limits.kdfSaltBytes
    )

    /// Test bounds: like ``password`` but down to ``KDFParameters/testing``. Never use outside tests
    /// and previews.
    public static let testing = KDFBounds(
        opsLimit: KDFParameters.testingOpsLimit...UInt32(Limits.passwordKDFOpsLimitMax),
        memLimitBytes: KDFParameters.testingMemoryBytes...UInt64(Limits.passwordKDFMemoryBytesMax),
        saltBytes: Limits.kdfSaltBytes
    )

    /// True when `parameters` and a salt of `saltCount` bytes are inside the bounds.
    public func contains(_ parameters: KDFParameters, saltCount: Int) -> Bool {
        opsLimit.contains(parameters.opsLimit)
            && memLimitBytes.contains(parameters.memLimitBytes)
            && saltCount == saltBytes
    }
}

/// The KDF configuration a vault is created and opened with: parameters for new wraps and the
/// bounds for stored ones. Injected by the composition root (``production`` in the app,
/// ``testing`` in tests and previews).
public struct KDFPolicy: Sendable, Hashable {
    /// Parameters for new password wraps.
    public let parameters: KDFParameters
    /// Bounds for stored password wraps.
    public let bounds: KDFBounds

    /// Fails at construction time if `parameters` would be rejected by `bounds`.
    public init?(parameters: KDFParameters, bounds: KDFBounds) {
        guard bounds.contains(parameters, saltCount: bounds.saltBytes) else { return nil }
        self.parameters = parameters
        self.bounds = bounds
    }

    private init(validParameters: KDFParameters, bounds: KDFBounds) {
        parameters = validParameters
        self.bounds = bounds
    }

    /// ``KDFParameters/moderate`` within ``KDFBounds/password``.
    public static let production = KDFPolicy(validParameters: .moderate, bounds: .password)
    /// ``KDFParameters/testing`` within ``KDFBounds/testing``.
    public static let testing = KDFPolicy(validParameters: .testing, bounds: .testing)
}
