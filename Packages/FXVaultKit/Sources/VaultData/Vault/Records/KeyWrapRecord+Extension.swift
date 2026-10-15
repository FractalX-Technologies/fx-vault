import Foundation
import VaultCore
import VaultCrypto
import VaultStore

extension KeyWrapRecord {
    /// The row for a wrap produced by `KeyWrap`.
    init(_ wrap: KeyWrapModel, updatedAt: Date) {
        let method: VaultStore.KeyWrapMethod = switch wrap.method {
        case .password: .password
        case .recovery: .recovery
        }
        let kdf: KeyWrapKDF = switch wrap.kdfAlgorithm {
        case .argon2id13: .argon2id13
        case .hkdfSHA256: .hkdfSHA256
        }
        self.init(
            method: method,
            kdf: kdf,
            opsLimit: wrap.storedOpsLimit.flatMap { Int(exactly: $0) },
            memLimitBytes: wrap.storedMemLimitBytes.flatMap { Int(exactly: $0) },
            salt: wrap.salt,
            wrappedDEK: wrap.wrappedDEK,
            dekVersion: Int(wrap.dekVersion),
            updatedAt: updatedAt
        )
    }

    /// The VaultCrypto model of this row. Every bound is checked again by `KeyWrap` before the
    /// KDF runs.
    ///
    /// - Throws: `.corrupted(...)` for values no build writes.
    func model() throws(VaultError) -> KeyWrapModel {
        try KeyWrapModel(
            storedMethod: method.rawValue,
            kdfAlgorithm: Int64(kdf.rawValue),
            opsLimit: opsLimit.map { Int64($0) },
            memLimitBytes: memLimitBytes.map { Int64($0) },
            salt: salt,
            wrappedDEK: wrappedDEK,
            dekVersion: Int64(dekVersion)
        )
    }
}
