import CryptoKit
import Foundation
import VaultCore

/// Constants of remote pairing (v0.9.0, P4): Add Teammate › Not Nearby…, by two `.fxvcard`
/// files (an invitation and its reply) and a 6-word code the two people compare on a call.
/// Documented in docs/SHARING-PROTOCOL.md §10.9; pinned by Fixtures/pairing_kat.json.
public enum RemotePairingProtocol {
    /// Protocol name, for documentation and diagnostics.
    public static let name = "fxvault/pair-remote/v1"
    /// The `.fxvcard` format version.
    public static let version: UInt8 = 1
    /// `FXVCARD` followed by 0x1A.
    public static let magic: [UInt8] = [0x46, 0x58, 0x56, 0x43, 0x41, 0x52, 0x44, 0x1A]
    /// The file extension of a teammate card.
    public static let fileExtension = "fxvcard"
    /// The exported UTType of a teammate card. Must match `UTExportedTypeDeclarations` in project.yml.
    public static let typeIdentifier = "io.fractalx.fxvault.teammate-card"
    /// The MIME type of a teammate card.
    public static let mimeType = "application/vnd.fractalx.fxvault-card"

    /// Prefix of every remote pairing label.
    static let labelPrefix = "fxvault/pair-remote/v1"
    /// What the inviter signs first: `LP(label) ‖ LP(publicCard ‖ createdAt ‖ nonce)`.
    static let invitationSignatureLabel = Data("\(labelPrefix)/invite".utf8)
    /// What the replier signs first: `LP(label) ‖ LP(reply body before the signature)`.
    static let replySignatureLabel = Data("\(labelPrefix)/reply".utf8)
    /// HPKE info of the replier's sealed announce key, followed by `SHA256(invitation) ‖ deviceID`.
    static let announceLabel = Data("\(labelPrefix)/announce".utf8)
    /// First element of the code transcript.
    static let codeLabel = Data("\(labelPrefix)/code".utf8)
    /// HKDF info of the stream the code words are drawn from.
    static let codeWordsInfo = Data("\(labelPrefix)/code-words".utf8)

    /// The HPKE suite of the sealed announce key (the spaces suite).
    static let sealSuite = SpaceProtocol.wrapSuite
    /// Bytes of the HPKE encapsulated key (X25519).
    static let encapsulatedKeyBytes = 32
    /// Bytes of the sealed announce key: the key plus a ChaCha20-Poly1305 tag.
    static let sealedAnnounceBytes = TeamProtocol.announceKeyBytes + 16
    /// Bytes of the code word stream (HKDF output). Six accepted draws almost never need more
    /// than 12 bytes; 128 make running out less likely than 2^-200.
    static let codeStreamBytes = 128
    /// Words in a code (as many as a passphrase).
    public static let codeWordCount = Limits.passphraseWordCount
    /// Bytes of the header: magic, version and kind.
    static let headerBytes = magic.count + 2
}

/// What a `.fxvcard` file is.
public enum RemotePairingFileKind: UInt8, Sendable, Hashable, CaseIterable {
    /// A new teammate's invitation (step 1).
    case invitation = 1
    /// The answer to this Mac's invitation (step 2).
    case reply = 2
}
