import CryptoKit
import Foundation
import VaultCore

/// Seals and opens `.fxvault` v1 files (§9.1, D23): `header(64) ‖ ciphertext ‖ tag(16)`,
/// AES-256-GCM under an Argon2id key, with the whole header as AAD.
///
/// Reading follows the §9.1 order. ``inspect(_:)`` runs steps 1–6 without a passphrase so the
/// UI can reject a damaged file before asking for one; ``open(_:passphrase:)`` repeats them and
/// only then calls the injected ``KeyDeriving``. Every read failure is
/// ``ShareError/invalidFile``.
public struct FxVaultFileCodec: Sendable {
    private let deriver: any KeyDeriving

    public init(deriver: any KeyDeriving) {
        self.deriver = deriver
    }

    // MARK: - Reading

    /// Steps 1–6: size, magic, version, header length, ids, bounds and reserved bytes.
    /// Never derives a key.
    public static func inspect(_ file: Data) throws(ShareError) -> FxVaultHeaderModel {
        let minimumSize = Limits.shareHeaderBytes + Limits.gcmTagBytes
        guard file.count <= Limits.maxShareFileBytes, file.count >= minimumSize else {
            throw .invalidFile
        }
        return try FxVaultHeaderModel.parse(file)
    }

    /// Steps 1–9: checks the header, derives the key, authenticates and decrypts.
    /// Returns the plaintext JSON (the caller wipes it). `passphrase` must already be
    /// normalized (``PassphraseGenerator/normalize(_:)``).
    public func decrypt(_ file: Data, passphrase: SecretBytes) async throws(ShareError) -> SecretBytes {
        let header = try Self.inspect(file)
        let headerBytes = header.encoded()
        let fileHeader = file.bytes(at: 0, length: Limits.shareHeaderBytes)
        guard fileHeader == headerBytes,
              let sealed = file.bytes(
                  at: Limits.shareHeaderBytes,
                  length: file.count - Limits.shareHeaderBytes
              )
        else { throw .invalidFile }
        let key = try await deriveKey(passphrase: passphrase, header: header, failure: .invalidFile)
        do {
            let nonce = try AES.GCM.Nonce(data: header.nonce)
            let box = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: sealed.prefix(sealed.count - Limits.gcmTagBytes),
                tag: sealed.suffix(Limits.gcmTagBytes)
            )
            var plaintext = try AES.GCM.open(box, using: key, authenticating: headerBytes)
            defer { plaintext.wipe() }
            guard plaintext.count <= Limits.maxSharePayloadBytes else { throw ShareError.invalidFile }
            return SecretBytes(plaintext)
        } catch {
            throw .invalidFile
        }
    }

    /// Steps 1–11: decrypts, decodes the JSON and validates the package (payload mode).
    /// The replay check (step 12) belongs to ``ShareImportPlanner``.
    public func open(_ file: Data, passphrase: SecretBytes) async throws(ShareError) -> SharePackageModel {
        let json = try await decrypt(file, passphrase: passphrase)
        defer { json.wipe() }
        let package = try SharePackageCoder.decode(json)
        do {
            try SharePackageValidator.validate(package, mode: .payload)
        } catch {
            package.wipeValues()
            throw error
        }
        return package
    }

    // MARK: - Writing

    /// Seals `payload` (UTF-8 JSON) under a fresh header: new salt and nonce for every export.
    public func encrypt(payload: SecretBytes, passphrase: SecretBytes) async throws(ShareError) -> Data {
        try await encrypt(payload: payload, passphrase: passphrase, header: .fresh())
    }

    /// Validates, encodes and seals `package` under a fresh header.
    public func seal(_ package: SharePackageModel, passphrase: SecretBytes) async throws(ShareError) -> Data {
        try SharePackageValidator.validate(package, mode: .payload)
        let json = try SharePackageCoder.encode(package)
        defer { json.wipe() }
        return try await encrypt(payload: json, passphrase: passphrase)
    }

    /// Seals `payload` under `header`. Exposed for known-answer tests; production code uses
    /// ``encrypt(payload:passphrase:)`` so the salt and nonce are always fresh.
    func encrypt(
        payload: SecretBytes,
        passphrase: SecretBytes,
        header: FxVaultHeaderModel
    ) async throws(ShareError) -> Data {
        guard payload.count <= Limits.maxSharePayloadBytes else { throw .payloadTooLarge }
        let key = try await deriveKey(passphrase: passphrase, header: header, failure: .encryptionFailed)
        let headerBytes = header.encoded()
        do {
            let nonce = try AES.GCM.Nonce(data: header.nonce)
            let box = try payload.withUnsafeBytes { bytes in
                try AES.GCM.seal(bytes, using: key, nonce: nonce, authenticating: headerBytes)
            }
            return headerBytes + box.ciphertext + box.tag
        } catch {
            throw .encryptionFailed
        }
    }

    // MARK: - Private

    private func deriveKey(
        passphrase: SecretBytes,
        header: FxVaultHeaderModel,
        failure: ShareError
    ) async throws(ShareError) -> SymmetricKey {
        let derived: SecretBytes
        do {
            derived = try await deriver.deriveKey(
                passphrase: passphrase,
                parameters: header.keyDerivationParameters
            )
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw failure
        }
        defer { derived.wipe() }
        guard derived.count == Limits.dekBytes else { throw failure }
        return derived.withUnsafeBytes { SymmetricKey(data: $0) }
    }
}
