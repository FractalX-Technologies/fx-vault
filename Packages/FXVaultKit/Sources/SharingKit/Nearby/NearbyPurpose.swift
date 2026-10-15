import Foundation

/// What a nearby connection is for. Each purpose has its own Bonjour service type and its own
/// prefix for every hash and HKDF label (commitment, transcript, SAS, direction keys), so a share
/// session can never be completed as a chat session or the other way round: the commitment check
/// fails first, and even without it the SAS and the keys would differ.
public enum NearbyPurpose: String, Sendable, Hashable, CaseIterable {
    /// Nearby share, protocol `fxvault-nearby/v1` (§9.4).
    case share
    /// Nearby chat, protocol `fxvault-chat/v1`.
    case chat

    /// The Bonjour service type advertised and browsed for this purpose. Each must be listed in
    /// `NSBonjourServices` (project.yml).
    public var bonjourServiceType: String {
        switch self {
        case .share: NearbyProtocol.bonjourServiceType
        case .chat: NearbyChatProtocol.bonjourServiceType
        }
    }

    /// The highest protocol version this Mac offers in HELLO for this purpose. A session runs at
    /// `min(maxVerI, maxVerR)`, bound into the transcript (§4 step 4): share stays at 1, chat is
    /// 2 since v0.4.0 (configuration attachments, ``NearbyChatProtocol/configurationAttachmentsVersion``).
    var maxVersion: UInt8 {
        switch self {
        case .share: NearbyProtocol.maxVersion
        case .chat: NearbyChatProtocol.maxVersion
        }
    }

    /// The domain-separation labels of this purpose.
    var labels: NearbyLabels {
        switch self {
        case .share: .share
        case .chat: .chat
        }
    }
}

/// The five domain-separation labels of one purpose: `<prefix>/commit`, `<prefix>/transcript`,
/// `<prefix>/sas`, `<prefix>/key/i2r` and `<prefix>/key/r2i`.
struct NearbyLabels: Sendable, Hashable {
    let commit: Data
    let transcript: Data
    let sas: Data
    let initiatorToResponder: Data
    let responderToInitiator: Data

    init(prefix: String) {
        commit = Data("\(prefix)/commit".utf8)
        transcript = Data("\(prefix)/transcript".utf8)
        sas = Data("\(prefix)/sas".utf8)
        initiatorToResponder = Data("\(prefix)/key/i2r".utf8)
        responderToInitiator = Data("\(prefix)/key/r2i".utf8)
    }

    /// `fxvault/nearby/v1/...` (unchanged since 0.1.0; pinned by nearby_kat.json).
    static let share = NearbyLabels(prefix: NearbyProtocol.labelPrefix)
    /// `fxvault/chat/v1/...` (pinned by chat_kat.json).
    static let chat = NearbyLabels(prefix: NearbyChatProtocol.labelPrefix)
}
