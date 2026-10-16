import Foundation
import VaultCore

/// Constants of `fxvault-team/v1` (v0.5.0, tasks/todo.md T1–T8): Add Teammate (pairing),
/// presence pseudonyms, the paired handshake and pings. Documented in docs/SHARING-PROTOCOL.md
/// §10; pinned by Fixtures/team_kat.json.
public enum TeamProtocol {
    /// Protocol name, for documentation and diagnostics.
    public static let name = "fxvault-team/v1"
    /// The protocol version (HELLO, card format, preamble).
    public static let version: UInt8 = 1

    /// Bonjour type of Add Teammate: advertised under the display name only while the sheet is
    /// open. Must match `NSBonjourServices` in project.yml.
    public static let pairingServiceType = "_fxvault-pair._tcp"
    /// Bonjour type of presence: rotating pseudonyms (``TeamPseudonym``). Must match
    /// `NSBonjourServices` in project.yml.
    public static let presenceServiceType = "_fxvault-team._tcp"

    /// Prefix of every pairing label (``NearbyLabels/pair``).
    static let pairLabelPrefix = "fxvault/pair/v1"
    /// Prefix of every presence and paired-handshake label (``NearbyLabels/team``).
    static let labelPrefix = "fxvault/team/v1"

    /// `deviceID = SHA256(LP(label) ‖ LP(signingPK) ‖ LP(agreementPK))[0..<16]`.
    static let deviceIDLabel = Data("\(labelPrefix)/device-id".utf8)
    /// `pseudonym = HMAC-SHA256(announceKey, LP(label) ‖ u64be(window))[0..<16]`.
    static let pseudonymLabel = Data("\(labelPrefix)/announce".utf8)
    /// What a pairing card signature covers first: `LP(label) ‖ u8(role) ‖ LP(TH) ‖ LP(card)`.
    static let cardSignatureLabel = Data("\(pairLabelPrefix)/card".utf8)
    /// What AUTH_I signs first: `LP(label) ‖ LP(TH) ‖ LP(deviceID_I) ‖ LP(deviceID_R)`.
    static let initiatorAuthLabel = Data("\(labelPrefix)/auth-i".utf8)
    /// What AUTH_R signs first: `LP(label) ‖ LP(TH) ‖ LP(deviceID_I) ‖ LP(deviceID_R)`.
    static let responderAuthLabel = Data("\(labelPrefix)/auth-r".utf8)
    /// What a chat IDENT signs first (chat version 3): `LP(label) ‖ u8(role) ‖ LP(TH)`.
    static let chatIdentLabel = Data("\(labelPrefix)/chat-ident".utf8)

    /// Bytes of a device id.
    public static let deviceIDBytes = 16
    /// Bytes of the announce key that seeds a device's pseudonyms.
    public static let announceKeyBytes = 32
    /// Bytes of an Ed25519 or X25519 public key, and of an Ed25519 private key seed.
    public static let keyBytes = 32
    /// Bytes of an Ed25519 signature.
    public static let signatureBytes = 64
    /// Bytes of a pseudonym (32 hex characters in the instance name).
    public static let pseudonymBytes = 16
    /// A pseudonym changes every window (15 minutes); a teammate also accepts the windows
    /// around the current one, so clocks may differ by a few minutes.
    public static let pseudonymWindowSeconds: Int64 = 15 * 60
    /// Windows accepted on each side of the current one when matching a pseudonym.
    public static let pseudonymWindowTolerance: Int64 = 1
    /// Largest login, display name or Mac name in a card, in UTF-8 bytes.
    public static let maxCardStringBytes = Limits.maxDisplayNameBytes
    /// Bytes of the handshake nonces (`nI`, `nR`).
    static let nonceBytes = NearbyProtocol.nonceBytes
}

/// What a connection to the presence service is for: the plaintext preamble, the first frame
/// an initiator sends (`0x50 ‖ ver ‖ service`). Only routing: every service then runs its own
/// purpose-bound handshake, so a lie about the service fails there.
public enum TeamService: UInt8, Sendable, Hashable, CaseIterable {
    /// The paired handshake, then a request (PING).
    case team = 0x01
    /// A nearby chat (`fxvault-chat`) started from a teammate's bubble.
    case chat = 0x02
    /// The paired handshake, then shared space versions only (v0.6.0, S6): the only service a
    /// teammate's address outside the local network accepts (Q4).
    case spaces = 0x03

    /// The preamble frame.
    public var preamble: Data {
        Data([TeamMessageType.preamble.rawValue, TeamProtocol.version, rawValue])
    }

    /// Reads a preamble frame. Nil for anything else (the listener closes the connection).
    public static func decodePreamble(_ frame: Data) -> TeamService? {
        guard frame.count == 3,
              frame[frame.startIndex] == TeamMessageType.preamble.rawValue,
              frame[frame.startIndex + 1] == TeamProtocol.version
        else { return nil }
        return TeamService(rawValue: frame[frame.startIndex + 2])
    }
}

/// Frame types of pairing and of the paired handshake. HELLO_I, HELLO_R, REVEAL_I, CONFIRM,
/// CLOSE and ABORT keep their nearby values; pairing adds CARD, the paired handshake its own
/// plaintext hellos and encrypted AUTH, PING and PONG.
public enum TeamMessageType: UInt8, Sendable, Hashable, CaseIterable {
    /// Body `0x01` (as in share and chat).
    case confirm = 0x10
    /// Pairing: `u16 cardLength ‖ card ‖ signature(64)`.
    case card = 0x40
    /// Plaintext routing preamble (``TeamService``).
    case preamble = 0x50
    /// Plaintext: `ver ‖ ephemeralPK_I(32) ‖ nonce_I(32)`.
    case helloInitiator = 0x51
    /// Plaintext: `ver ‖ ephemeralPK_R(32) ‖ nonce_R(32)`.
    case helloResponder = 0x52
    /// Encrypted: `deviceID_I(16) ‖ signature(64)`.
    case authInitiator = 0x53
    /// Encrypted: `deviceID_R(16) ‖ signature(64)`.
    case authResponder = 0x54
    /// Encrypted, empty body: "your teammate pinged you".
    case ping = 0x60
    /// Encrypted, empty body: the answer to a PING.
    case pong = 0x61
    /// Encrypted: the sender's card with a new announce key (after it removed a teammate).
    case cardUpdate = 0x62
    /// Encrypted, empty body: the card update was stored.
    case cardUpdated = 0x63
    /// Encrypted (spaces service), I → R: `u16 count ‖ (spaceID(16) ‖ u64 version ‖ hash(32))*`,
    /// the initiator's heads of the spaces it shares with R.
    case spaceHeads = 0x64
    /// Encrypted (spaces service), R → I: the responder's heads of the spaces it shares with I.
    case spaceHeadsReply = 0x65
    /// Encrypted (spaces service), I → R: `spaceID(16) ‖ u64 version`, one version to send.
    case spaceFetch = 0x66
    /// Encrypted (spaces service), R → I: `u32 length` of the version that follows in
    /// SPACE_CHUNK frames; 0 when R does not have it or I is not a member.
    case spaceVersion = 0x67
    /// Encrypted (spaces service), R → I: the next bytes of the version.
    case spaceChunk = 0x68
    /// Empty body. Ends a session normally.
    case close = 0x7E
    /// Body: one ``NearbyAbortCode`` (plaintext before keys, encrypted after).
    case abort = 0x7F
}
