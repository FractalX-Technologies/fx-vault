import Foundation
import VaultCore

/// Constants of nearby protocol v1 (§9.4, D21).
public enum NearbyProtocol {
    /// Highest protocol version this build speaks (`maxVer`).
    public static let maxVersion: UInt8 = 1
    /// Lowest acceptable negotiated version.
    public static let minVersion: UInt8 = 1
    /// Suite 1: X25519 + HKDF-SHA256 + AES-256-GCM + SHA-256.
    public static let suite: UInt8 = 1

    /// Bonjour service type (TCP only, D22). Must match `NSBonjourServices` in Info.plist.
    public static let bonjourServiceType = "_fxvault-share._tcp"
    /// TXT record key and value advertised by the receiver (nothing else is advertised).
    public static let txtVersionKey = "v"
    public static let txtVersionValue = "1"

    /// Domain-separation labels.
    static let labelCommit = Data("fxvault/nearby/v1/commit".utf8)
    static let labelTranscript = Data("fxvault/nearby/v1/transcript".utf8)
    static let labelSAS = Data("fxvault/nearby/v1/sas".utf8)
    static let labelInitiatorToResponder = Data("fxvault/nearby/v1/key/i2r".utf8)
    static let labelResponderToInitiator = Data("fxvault/nearby/v1/key/r2i".utf8)

    /// X25519 public key size.
    public static let publicKeyBytes = 32
    /// Handshake nonce size (`nI`, `nR`).
    public static let nonceBytes = 32
    /// SHA-256 output size (commitment, transcript hash, payload digest).
    public static let hashBytes = 32
    /// HKDF output used for the SAS (a big-endian UInt64).
    public static let sasKeyBytes = 8
    /// HKDF output for each direction key (AES-256).
    public static let directionKeyBytes = Limits.dekBytes
    /// `10^6`: the SAS is the HKDF UInt64 modulo this.
    public static let sasModulus: UInt64 = 1_000_000
    /// Digits per displayed SAS group (`ddd ddd`).
    public static let sasGroupSize = 3

    /// `[ver][type][seq:8]`: the encrypted frame header, also the AAD.
    public static let encryptedHeaderBytes = 10
    /// Zero bytes in front of the 8-byte sequence number in the GCM nonce.
    static let nonceZeroPrefixBytes = Limits.gcmNonceBytes - MemoryLayout<UInt64>.size
    /// Largest plaintext carried by one encrypted frame.
    public static let maxFramePlaintextBytes =
        Limits.maxNearbyEncryptedFrameBytes - encryptedHeaderBytes - Limits.gcmTagBytes
    /// Largest frame either side accepts from the transport.
    public static let maxTransportFrameBytes = max(
        Limits.maxNearbyEncryptedFrameBytes,
        Limits.maxNearbyHandshakeFrameBytes
    )
    /// Body of a CONFIRM frame.
    static let confirmBody = Data([0x01])
    /// Size of the u32 total length that opens the first MANIFEST frame.
    static let manifestLengthBytes = MemoryLayout<UInt32>.size
    /// Size of the u16 display-name length in HELLO frames.
    static let nameLengthBytes = MemoryLayout<UInt16>.size
}

/// Frame types (§9.4). 0x01–0x03 and plaintext ABORT travel before keys exist; everything
/// else, including ABORT after keys, is encrypted.
public enum NearbyMessageType: UInt8, Sendable, Hashable, CaseIterable {
    case helloInitiator = 0x01
    case helloResponder = 0x02
    case revealInitiator = 0x03
    case confirm = 0x10
    case manifest = 0x11
    case decision = 0x12
    case payloadChunk = 0x13
    case payloadEnd = 0x14
    case result = 0x15
    case close = 0x7E
    case abort = 0x7F
}

/// Which side of the protocol this device plays.
public enum NearbyRole: String, Sendable, Hashable, CaseIterable {
    /// I: the sender. Browses, connects, sends HELLO_I, MANIFEST and PAYLOAD.
    case initiator
    /// R: the receiver. Advertises only while "Receive nearby" is open; sends DECISION, RESULT.
    case responder
}

/// The timer that guards the current phase (§9.4 timeouts). The 10-minute session limit
/// applies on top of every phase.
public enum NearbyTimeoutKind: String, Sendable, Hashable, CaseIterable {
    /// HELLO through REVEAL: ``Timeouts/nearbyHandshake``.
    case handshake
    /// Comparing the code until both confirmations: ``Timeouts/nearbySAS``.
    case sas
    /// Silence while the peer's device should be streaming: ``Timeouts/nearbyIdle``.
    case idle
    /// The whole session: ``Timeouts/nearbySession``.
    case session

    /// The duration of this timer.
    public var duration: Duration {
        switch self {
        case .handshake: Timeouts.nearbyHandshake
        case .sas: Timeouts.nearbySAS
        case .idle: Timeouts.nearbyIdle
        case .session: Timeouts.nearbySession
        }
    }
}

/// Why a nearby session aborted (§9.4 abort conditions). Every abort wipes the keys and is
/// final: no resume and no automatic retry.
public enum NearbyAbortReason: Sendable, Hashable {
    case unsupportedVersion
    case unsupportedSuite
    case suiteMismatch
    case unexpectedMessage
    case commitmentMismatch
    /// A low-order or otherwise invalid X25519 key, or an all-zero shared secret.
    case invalidKey
    /// AES-GCM authentication failed (tampering, wrong direction, or a MITM's keys).
    case decryptionFailed
    /// Replay, reorder or a gap in the per-direction sequence.
    case sequenceMismatch
    /// The sequence space (``Limits/maxNearbySequence``) is exhausted.
    case sequenceExhausted
    case oversizeFrame
    /// A frame that cannot be parsed (truncated, bad lengths, bad UTF-8, trailing bytes).
    case malformedFrame
    /// PAYLOAD_END length or SHA-256 mismatch, or a payload that is not what was accepted.
    case payloadMismatch
    /// The payload exceeds ``Limits/maxNearbyPayloadBytes``.
    case payloadTooLarge
    /// DECISION listed ids that are not in the manifest.
    case unknownItemIDs
    /// A received MANIFEST or PAYLOAD broke a `SharePackageValidator` rule.
    case invalidPackage(SharePackageViolation)
    /// This side's user pressed "Don't match".
    case sasRejected
    /// The local user or app cancelled.
    case cancelled
    case timeout(NearbyTimeoutKind)
    case disconnected
    /// A second peer tried to connect during the session.
    case secondPeer
    /// The peer sent ABORT with this reason code (unauthenticated before keys).
    case peerAborted(NearbyAbortCode)

    /// The one-byte code sent in an ABORT frame for this reason.
    var code: NearbyAbortCode {
        switch self {
        case .unsupportedVersion: .unsupportedVersion
        case .unsupportedSuite, .suiteMismatch: .unsupportedSuite
        case .commitmentMismatch: .commitmentMismatch
        case .invalidKey: .invalidKey
        case .decryptionFailed: .decryptionFailed
        case .sasRejected: .sasRejected
        case .cancelled, .disconnected, .secondPeer, .peerAborted: .cancelled
        case .timeout: .timeout
        case .unexpectedMessage, .sequenceMismatch, .sequenceExhausted, .oversizeFrame,
             .malformedFrame, .payloadMismatch, .payloadTooLarge, .unknownItemIDs, .invalidPackage:
            .protocolError
        }
    }
}

/// Reason codes carried by ABORT frames. Unknown codes from a peer map to `.protocolError`.
public enum NearbyAbortCode: UInt8, Sendable, Hashable, CaseIterable {
    case protocolError = 0x01
    case unsupportedVersion = 0x02
    case unsupportedSuite = 0x03
    case commitmentMismatch = 0x04
    case invalidKey = 0x05
    case decryptionFailed = 0x06
    case sasRejected = 0x07
    case timeout = 0x08
    case cancelled = 0x09
}

/// A finished-with-error outcome as the UI needs it.
public struct NearbyAbortModel: Sendable, Hashable {
    public var reason: NearbyAbortReason
    /// True when the abort happened after REVEAL (keys and SAS existed). With
    /// ``isSecurityRelevant`` this drives the "Someone nearby may be trying to intercept this
    /// share." warning (§9.4); see ``NearbyFailureTracker``.
    public var happenedAfterReveal: Bool

    public init(reason: NearbyAbortReason, happenedAfterReveal: Bool) {
        self.reason = reason
        self.happenedAfterReveal = happenedAfterReveal
    }

    /// Aborts that a local cancel or a plain timeout cannot explain.
    public var isSecurityRelevant: Bool {
        switch reason {
        case .cancelled, .disconnected, .timeout:
            false
        case .peerAborted(let code):
            code != .cancelled && code != .timeout
        default:
            true
        }
    }

    /// Whether this abort alone warrants the interception warning.
    public var suggestsInterception: Bool {
        (happenedAfterReveal && isSecurityRelevant) || reason == .commitmentMismatch
    }
}

/// Counts failed handshakes in a row for the interception warning (§9.4: "after an abort that
/// follows REVEAL, or two failed handshakes in a row"). Kept by the app for one sheet.
public struct NearbyFailureTracker: Sendable, Hashable {
    public private(set) var consecutiveFailures = 0

    public init() {}

    /// Records an abort and returns whether to show the interception warning.
    public mutating func record(_ abort: NearbyAbortModel) -> Bool {
        if abort.reason == .cancelled { return false }
        consecutiveFailures += 1
        return abort.suggestsInterception
            || consecutiveFailures >= Limits.nearbyFailedHandshakeWarningThreshold
    }

    /// Records a session that completed (or was declined) normally.
    public mutating func recordSuccess() {
        consecutiveFailures = 0
    }
}

/// The short authentication string both users compare (§9.4 step 5).
public struct NearbySASModel: Sendable, Hashable {
    /// `0..<10^6`.
    public let value: UInt64
    /// The sanitized peer display name (unverified until the codes match).
    public let peerName: String

    public init(value: UInt64, peerName: String) {
        self.value = value
        self.peerName = peerName
    }

    /// `ddd ddd`, zero-padded.
    public var code: String {
        let digits = String(value)
        let padded = String(repeating: "0", count: max(0, Limits.nearbySASDigits - digits.count)) + digits
        let split = padded.index(padded.startIndex, offsetBy: NearbyProtocol.sasGroupSize)
        return "\(padded[..<split]) \(padded[split...])"
    }
}

/// The receiver's DECISION (§9.4 step 8).
public struct NearbyDecisionModel: Sendable, Hashable {
    public var accept: Bool
    /// Selected manifest entry ids (items and environments). Empty when declined.
    public var itemIDs: Set<ShareEntryID>

    public init(accept: Bool, itemIDs: Set<ShareEntryID>) {
        self.accept = accept
        self.itemIDs = accept ? itemIDs : []
    }

    /// A decline.
    public static let decline = NearbyDecisionModel(accept: false, itemIDs: [])
}
