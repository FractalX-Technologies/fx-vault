import CryptoKit
import Foundation
import VaultCore

/// Seals and opens `.fxvault` format 2 files (v0.9.0, SHARING-PROTOCOL.md §2.1) and still opens
/// v1 files through ``FxVaultFileCodec``.
///
/// - **Passphrase mode:** `header(64) ‖ ciphertext ‖ tag(16)`, AES-256-GCM under the Argon2id key
///   of a six-word passphrase, AAD = header. Exactly v1 apart from the header.
/// - **Teammates mode:** `header(64) ‖ slots(88 × n) ‖ ciphertext ‖ tag(16)`. A random content key
///   is wrapped with HPKE for each recipient's X25519 key; slots carry only an opaque id
///   (`HMAC(salt, deviceID)` prefix), sorted. AES-256-GCM under the content key, AAD = header ‖
///   slots. The plaintext starts with the sender's device id, announce key and an Ed25519
///   signature over the header, the slots, both of those and the payload digest.
///
/// Reading checks the size and every header and slot rule first (``inspect(_:)``, no key
/// material), and only then derives or unwraps a key. Every structural or cryptographic failure
/// is ``ShareError/invalidFile``; a file for other teammates is ``ShareError/notARecipient`` and
/// one from a device that is not a teammate is ``ShareError/senderNotTeammate``.
public struct FxVaultFileV2Codec: Sendable {
    private let deriver: any KeyDeriving

    public init(deriver: any KeyDeriving) {
        self.deriver = deriver
    }

    // MARK: - Inspecting

    /// Size, magic, version, then the header of that version and (teammates mode) the slots.
    /// Never derives or unwraps a key.
    public static func inspect(_ file: Data) throws(ShareError) -> FxVaultFileInfo {
        guard file.count <= Limits.maxShareFileV2Bytes,
              file.bytes(at: FxVaultHeaderV2Model.Offset.magic, length: FxVaultHeaderModel.magic.count)
              == Data(FxVaultHeaderModel.magic),
              let version = file.readBigEndian(UInt16.self, at: FxVaultHeaderV2Model.Offset.formatVersion)
        else { throw .invalidFile }
        switch version {
        case FxVaultHeaderModel.formatVersion:
            return .v1(try FxVaultFileCodec.inspect(file))
        case FxVaultHeaderV2Model.formatVersion:
            let header = try FxVaultHeaderV2Model.parse(file)
            switch header.mode {
            case .passphrase:
                guard file.count <= Limits.maxShareFileBytes,
                      file.count >= Limits.shareHeaderBytes + Limits.gcmTagBytes
                else { throw .invalidFile }
                return .v2Passphrase(header)
            case .teammates:
                let layout = TeammatesLayout(recipientCount: header.recipientCount)
                guard file.count >= layout.minimumFileBytes, file.count <= layout.maximumFileBytes else {
                    throw .invalidFile
                }
                _ = try FxVaultRecipientSlot.parseAll(file, at: Limits.shareHeaderBytes, count: header.recipientCount)
                return .v2Teammates(header, recipientCount: header.recipientCount)
            }
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
        guard header.mode == .passphrase else { throw .encryptionFailed }
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
    /// (``PassphraseGenerator/normalize(_:)``). A teammates file is `invalidFile`.
    public func openWithPassphrase(_ file: Data, passphrase: SecretBytes) async throws(ShareError) -> SecretBytes {
        switch try Self.inspect(file) {
        case .v1:
            return try await FxVaultFileCodec(deriver: deriver).decrypt(file, passphrase: passphrase)
        case .v2Teammates:
            throw .invalidFile
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

    // MARK: - Teammates mode

    /// Seals `payload` (UTF-8 JSON) for 1…``Limits/maxShareRecipients`` distinct teammates, signed by
    /// `sender`. Throws `encryptionFailed` for an empty, oversized or duplicated recipient list.
    public func sealForTeammates(
        payload: SecretBytes,
        sender: TeamDeviceKeys,
        recipients: [ShareTeammateKeyModel]
    ) throws(ShareError) -> Data {
        let header = try FxVaultHeaderV2Model.freshTeammates(recipientCount: recipients.count)
        return try sealForTeammates(
            payload: payload,
            sender: sender,
            recipients: recipients,
            header: header,
            contentKey: SymmetricKey(size: .bits256)
        )
    }

    /// Seals with a given header and content key. Exposed for tests; production code uses
    /// ``sealForTeammates(payload:sender:recipients:)``.
    func sealForTeammates(
        payload: SecretBytes,
        sender: TeamDeviceKeys,
        recipients: [ShareTeammateKeyModel],
        header: FxVaultHeaderV2Model,
        contentKey: SymmetricKey
    ) throws(ShareError) -> Data {
        guard header.mode == .teammates,
              header.recipientCount == recipients.count,
              Set(recipients.map(\.deviceID)).count == recipients.count
        else { throw .encryptionFailed }
        guard payload.count <= Limits.maxSharePayloadBytes else { throw .payloadTooLarge }
        let headerBytes = header.encoded()
        var slots: [FxVaultRecipientSlot] = []
        for recipient in recipients {
            slots.append(try FxVaultTeammateCrypto.wrap(contentKey: contentKey, header: headerBytes, salt: header.salt, for: recipient))
        }
        slots.sort { $0.slotID.lexicographicallyPrecedes($1.slotID) }
        guard Set(slots.map(\.slotID)).count == slots.count else { throw .encryptionFailed }
        let slotBytes = slots.reduce(into: Data()) { $0.append($1.encoded()) }

        let digest = payload.withUnsafeBytes { Data(SHA256.hash(data: $0)) }
        let message = FxVaultTeammateCrypto.signedMessage(
            header: headerBytes,
            slots: slotBytes,
            sender: sender.deviceID,
            announceKey: sender.announceKey,
            payloadDigest: digest
        )
        let signature: Data
        do {
            signature = try sender.signing.signature(for: message)
        } catch {
            throw .encryptionFailed
        }
        guard signature.count == TeamProtocol.signatureBytes else { throw .encryptionFailed }

        let plaintext = SecretBytes(count: Limits.shareSenderPrefixBytes + payload.count)
        defer { plaintext.wipe() }
        plaintext.withUnsafeMutableBytes { target in
            let prefix = sender.deviceID.bytes + sender.announceKey + signature
            target.copyBytes(from: prefix)
            payload.withUnsafeBytes { source in
                UnsafeMutableRawBufferPointer(rebasing: target[prefix.count...]).copyBytes(from: source)
            }
        }
        let aad = headerBytes + slotBytes
        let sealed = try plaintext.withUnsafeBytes { bytes throws(ShareError) in
            try Self.seal(bytes, key: contentKey, nonce: header.nonce, aad: aad)
        }
        return aad + sealed
    }

    /// Opens a teammates file addressed to `device`: finds its slot, unwraps the content key,
    /// decrypts, then checks the sender's signature with the matching key in `teammates`.
    public func openAsTeammate(
        _ file: Data,
        device: TeamDeviceKeys,
        teammates: [ShareTeammateKeyModel]
    ) throws(ShareError) -> FxVaultTeammateFileModel {
        guard case .v2Teammates(let header, let count) = try Self.inspect(file) else { throw .invalidFile }
        let headerBytes = header.encoded()
        let slotsEnd = Limits.shareHeaderBytes + count * Limits.shareRecipientSlotBytes
        guard file.bytes(at: 0, length: Limits.shareHeaderBytes) == headerBytes,
              let aad = file.bytes(at: 0, length: slotsEnd),
              let sealed = file.bytes(at: slotsEnd, length: file.count - slotsEnd)
        else { throw .invalidFile }
        let slots = try FxVaultRecipientSlot.parseAll(file, at: Limits.shareHeaderBytes, count: count)

        let ownSlotID = FxVaultTeammateCrypto.slotID(salt: header.salt, deviceID: device.deviceID)
        let candidates = slots.filter { $0.slotID == ownSlotID }
        guard !candidates.isEmpty else { throw .notARecipient }
        guard let contentKey = candidates.lazy.compactMap({
            FxVaultTeammateCrypto.unwrap($0, header: headerBytes, agreement: device.agreement)
        }).first else { throw .invalidFile }

        let plaintext = try Self.open(sealed, key: contentKey, nonce: header.nonce, aad: aad)
        defer { plaintext.wipe() }
        let payloadCount = plaintext.count - Limits.shareSenderPrefixBytes
        guard payloadCount >= 0, payloadCount <= Limits.maxSharePayloadBytes else { throw .invalidFile }

        let deviceIDBytes = TeamProtocol.deviceIDBytes
        let announceBytes = TeamProtocol.announceKeyBytes
        let (prefix, payload, digest) = plaintext.withUnsafeBytes { raw in
            let prefix = Data(raw.prefix(Limits.shareSenderPrefixBytes))
            let body = UnsafeRawBufferPointer(rebasing: raw[Limits.shareSenderPrefixBytes...])
            return (prefix, SecretBytes(copying: body), Data(SHA256.hash(data: body)))
        }
        guard let senderID = TeamDeviceID(bytes: prefix.prefix(deviceIDBytes)) else {
            payload.wipe()
            throw .invalidFile
        }
        let announceKey = Data(prefix.dropFirst(deviceIDBytes).prefix(announceBytes))
        let signature = Data(prefix.dropFirst(deviceIDBytes + announceBytes))
        guard let sender = teammates.first(where: { $0.deviceID == senderID }) else {
            payload.wipe()
            throw .senderNotTeammate
        }
        let slotBytes = Data(aad.dropFirst(Limits.shareHeaderBytes))
        let message = FxVaultTeammateCrypto.signedMessage(
            header: headerBytes,
            slots: slotBytes,
            sender: senderID,
            announceKey: announceKey,
            payloadDigest: digest
        )
        guard sender.isValidSignature(signature, for: message) else {
            payload.wipe()
            throw .invalidFile
        }
        return FxVaultTeammateFileModel(payload: payload, sender: senderID, senderAnnounceKey: announceKey)
    }

    // MARK: - Private

    /// The sizes of a teammates file with `recipientCount` slots.
    private struct TeammatesLayout {
        let recipientCount: Int

        var prefixBytes: Int {
            Limits.shareHeaderBytes + recipientCount * Limits.shareRecipientSlotBytes
        }

        var minimumFileBytes: Int {
            prefixBytes + Limits.shareSenderPrefixBytes + Limits.gcmTagBytes
        }

        var maximumFileBytes: Int {
            minimumFileBytes + Limits.maxSharePayloadBytes
        }
    }

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
