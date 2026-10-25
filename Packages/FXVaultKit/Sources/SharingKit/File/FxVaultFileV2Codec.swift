import CryptoKit
import Foundation
import VaultCore

/// Seals and opens `.fxvault` format 2 passphrase files (v0.9.0, SHARING-PROTOCOL.md §2.1) and
/// still opens v1 files through ``FxVaultFileCodec``: `header(64) ‖ ciphertext ‖ tag(16)`,
/// AES-256-GCM under the Argon2id key of a six-word passphrase, AAD = header.
///
/// Reading checks the size and every header rule first (``inspect(_:)``, no key material), and
/// only then derives a key. Every structural or cryptographic failure, including a 0.9 teammates
/// file, is ``ShareError/invalidFile``.
public struct FxVaultFileV2Codec: Sendable {
    private let deriver: any KeyDeriving

    public init(deriver: any KeyDeriving) {
        self.deriver = deriver
    }

    // MARK: - Inspecting

    /// Size, magic, version, then the header of that version. Never derives a key.
    public static func inspect(_ file: Data) throws(ShareError) -> FxVaultFileInfo {
        guard file.count <= Limits.maxShareFileBytes,
              file.bytes(at: FxVaultHeaderV2Model.Offset.magic, length: FxVaultHeaderModel.magic.count)
              == Data(FxVaultHeaderModel.magic),
              let version = file.readBigEndian(UInt16.self, at: FxVaultHeaderV2Model.Offset.formatVersion)
        else { throw .invalidFile }
        switch version {
        case FxVaultHeaderModel.formatVersion:
            return .v1(try FxVaultFileCodec.inspect(file))
        case FxVaultHeaderV2Model.formatVersion:
            let header = try FxVaultHeaderV2Model.parse(file)
            guard file.count >= Limits.shareHeaderBytes + Limits.gcmTagBytes else { throw .invalidFile }
            return .v2Passphrase(header)
        default:
            throw .invalidFile
        }
    }

    // MARK: - Passphrase mode

    /// Seals `payload` (UTF-8 JSON) under a fresh passphrase-mode header.
    public func sealWithPassphrase(payload: SecretBytes, passphrase: SecretBytes) async throws(ShareError) -> Data {
        try await sealWithPassphrase(payload: payload, passphrase: passphrase, header: .freshPassphrase())
    }

    /// Seals `payload` under `header`. Exposed for known-answer tests; production code uses
    /// ``sealWithPassphrase(payload:passphrase:)`` so the salt and nonce are always fresh.
    func sealWithPassphrase(
        payload: SecretBytes,
        passphrase: SecretBytes,
        header: FxVaultHeaderV2Model
    ) async throws(ShareError) -> Data {
        guard payload.count <= Limits.maxSharePayloadBytes else { throw .payloadTooLarge }
        let key = try await deriveKey(passphrase: passphrase, header: header, failure: .encryptionFailed)
        let headerBytes = header.encoded()
        let sealed = try payload.withUnsafeBytes { bytes throws(ShareError) in
            try Self.seal(bytes, key: key, nonce: header.nonce, aad: headerBytes)
        }
        return headerBytes + sealed
    }

    /// Opens a v1 file or a passphrase-mode format 2 file and returns its payload JSON (the
    /// caller wipes it). `passphrase` must already be normalized
    /// (``PassphraseGenerator/normalize(_:)``).
    public func openWithPassphrase(_ file: Data, passphrase: SecretBytes) async throws(ShareError) -> SecretBytes {
        switch try Self.inspect(file) {
        case .v1:
            return try await FxVaultFileCodec(deriver: deriver).decrypt(file, passphrase: passphrase)
        case .v2Passphrase(let header):
            let headerBytes = header.encoded()
            guard file.bytes(at: 0, length: Limits.shareHeaderBytes) == headerBytes,
                  let sealed = file.bytes(at: Limits.shareHeaderBytes, length: file.count - Limits.shareHeaderBytes)
            else { throw .invalidFile }
            let key = try await deriveKey(passphrase: passphrase, header: header, failure: .invalidFile)
            let plaintext = try Self.open(sealed, key: key, nonce: header.nonce, aad: headerBytes)
            guard plaintext.count <= Limits.maxSharePayloadBytes else {
                plaintext.wipe()
                throw .invalidFile
            }
            return plaintext
        }
    }

    // MARK: - Private

    private static func seal(_ plaintext: UnsafeRawBufferPointer, key: SymmetricKey, nonce: [UInt8], aad: Data) throws(ShareError) -> Data {
        do {
            let box = try AES.GCM.seal(plaintext, using: key, nonce: try AES.GCM.Nonce(data: nonce), authenticating: aad)
            return box.ciphertext + box.tag
        } catch {
            throw .encryptionFailed
        }
    }

    private static func open(_ sealed: Data, key: SymmetricKey, nonce: [UInt8], aad: Data) throws(ShareError) -> SecretBytes {
        guard sealed.count >= Limits.gcmTagBytes else { throw .invalidFile }
        do {
            let box = try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: nonce),
                ciphertext: sealed.prefix(sealed.count - Limits.gcmTagBytes),
                tag: sealed.suffix(Limits.gcmTagBytes)
            )
            var plaintext = try AES.GCM.open(box, using: key, authenticating: aad)
            defer { plaintext.wipe() }
            return SecretBytes(plaintext)
        } catch {
            throw .invalidFile
        }
    }

    private func deriveKey(
        passphrase: SecretBytes,
        header: FxVaultHeaderV2Model,
        failure: ShareError
    ) async throws(ShareError) -> SymmetricKey {
        let derived: SecretBytes
        do {
            derived = try await deriver.deriveKey(passphrase: passphrase, parameters: header.keyDerivationParameters)
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

/// What ``FxVaultFileV2Codec/inspect(_:)`` learns from a file without any key material.
public enum FxVaultFileInfo: Sendable, Hashable {
    /// A v1 file.
    case v1(FxVaultHeaderModel)
    /// A format 2 passphrase file.
    case v2Passphrase(FxVaultHeaderV2Model)
}
