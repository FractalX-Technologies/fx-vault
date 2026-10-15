import Foundation
import VaultCore

/// Constants of nearby chat protocol `fxvault-chat/v1` (docs/SHARING-PROTOCOL.md, "Nearby chat").
///
/// The handshake is the share handshake (commit-reveal X25519, 6-digit SAS, CONFIRM) run with
/// the chat labels; after both users confirm, the peers exchange encrypted chat frames in the
/// share frame layout. Nothing a chat session sends or receives is ever written to disk.
public enum NearbyChatProtocol {
    /// Protocol name, for documentation and diagnostics.
    public static let name = "fxvault-chat/v1"
    /// Bonjour service type of chat (TCP only). Must match `NSBonjourServices` in project.yml.
    public static let bonjourServiceType = "_fxvault-chat._tcp"
    /// Prefix of every chat label (``NearbyLabels/chat``): `fxvault/chat/v1/commit`, ...
    static let labelPrefix = "fxvault/chat/v1"

    /// Size of an attachment id on the wire.
    static let attachmentIDBytes = ChatAttachmentID.byteCount
}

/// Encrypted chat frame types. HELLO_I, HELLO_R, REVEAL_I and the plaintext ABORT are the share
/// handshake frames (``NearbyHandshakeFrame``); CONFIRM, CLOSE and ABORT keep their share type
/// bytes. Chat-only types live in `0x20…0x3F`; a share type such as MANIFEST is
/// `.unexpectedMessage` in a chat and every chat type is `.unexpectedMessage` in a share.
public enum NearbyChatMessageType: UInt8, Sendable, Hashable, CaseIterable {
    /// Body `0x01` (as in share).
    case confirm = 0x10
    /// Body: the message, UTF-8, 1…``Limits/chatMessageBytes`` bytes.
    case text = 0x20
    /// Body: `id(16) ‖ manifest JSON` (one secret or variable, names only, no value).
    case attachmentOffer = 0x21
    /// Body: `id(16)`. Sent by the receiver of an offer ("Save to my vault").
    case attachmentRequest = 0x22
    /// Body: `id(16) ‖ u32 totalLength ‖ chunk`. Chunks arrive in order; the last one completes
    /// the payload JSON (the offered manifest with its one value).
    case attachmentPayload = 0x23
    /// Body: `id(16)`. The receiver dismissed an offer, or the sender withdrew a requested one.
    case attachmentDecline = 0x24
    /// Empty body. Sent every ``Timeouts/chatKeepaliveInterval`` while chatting.
    case ping = 0x30
    /// Empty body. The answer to one PING.
    case pong = 0x31
    /// Empty body. Ends a verified chat normally.
    case close = 0x7E
    /// Body: one ``NearbyAbortCode``.
    case abort = 0x7F
}

/// Chat limits (local choices). Kept here rather than in VaultCore's `Limits.swift` because
/// only SharingKit enforces them; they are still read as `Limits.…`.
extension Limits {
    /// Largest chat message, in UTF-8 bytes (on the wire, and after sanitizing when sending).
    public static let chatMessageBytes = 4 * bytesPerKiB
    /// Largest attachment payload JSON. One value is at most ``maxValueBytes``; JSON escaping can
    /// grow it up to six times.
    public static let chatAttachmentBytes = 512 * bytesPerKiB
    /// Most open attachment offers per direction (offered or requested, not yet delivered).
    public static let chatMaxOpenAttachments = 8
    /// Keepalive PINGs that may be unanswered; the next keepalive tick aborts the chat.
    public static let chatMaxUnansweredPings = 2
    /// TEXT, offer, request, decline and PING frames the peer may send within one
    /// ``Timeouts/chatFloodWindow``; one more aborts with `unexpectedMessage`. A person typing
    /// never comes close; a flood must not grow memory or block the window.
    public static let chatMaxPeerFramesPerFloodWindow = 100
    /// Attachment offers the peer may make in one chat (open or not); one more aborts with
    /// `unexpectedMessage`, so offer-and-withdraw cannot run forever.
    public static let chatMaxOffersPerChat = 32
    /// Blank lines in a row a message may show (``ChatTextSanitizer``); more are dropped.
    public static let chatMaxBlankLines = 1
    /// Combining marks one character may carry (``ChatTextSanitizer``); NFC text in every
    /// script needs far fewer. Extra marks are dropped.
    public static let chatMaxMarksPerCharacter = 4
}

/// Chat timers (local choices). The handshake and the code comparison use the share timers
/// (``nearbyHandshake``, ``nearbySAS``); a chat has no whole-session limit.
extension Timeouts {
    /// A PING is sent this often while chatting.
    public static let chatKeepaliveInterval: Duration = .seconds(30)
    /// A chat with no message or attachment frame in either direction for this long ends.
    public static let chatIdle: Duration = .seconds(10 * secondsPerMinute)
    /// The window in which ``Limits/chatMaxPeerFramesPerFloodWindow`` applies.
    public static let chatFloodWindow: Duration = .seconds(10)
}
