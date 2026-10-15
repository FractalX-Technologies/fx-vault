import Foundation
import SharingKit
import VaultCore
import VaultData

/// Where the Nearby Chat window is (``NearbyChatViewModel/step``).
enum NearbyChatStep: Equatable {
    /// The vault is locked: nothing is advertised or browsed.
    case locked
    /// No network interface at all (Wi-Fi off and no cable). An internet connection is not
    /// needed: peer-to-peer Wi-Fi works without one.
    case unavailable
    /// Visible to nearby Macs and listing them; waiting for a choice or an incoming chat.
    case browsing
    /// Connecting to, or connected by, a peer (name unverified; nil until known).
    case connecting(peerName: String?)
    /// Both Macs show the code; waiting for "Codes match" / "Don't match".
    case comparing(NearbySASModel)
    /// Verified, end-to-end encrypted 1:1 chat.
    case chatting
    /// The conversation ended and everything was wiped.
    case ended(NearbyChatEndModel)
}

/// Why a conversation ended. Every end wipes the transcript and any received value.
struct NearbyChatEndModel: Equatable {
    enum Reason: Equatable {
        /// The other person ended the chat (CLOSE).
        case peerLeft
        /// This Mac ended it ("End Chat").
        case endedHere
        /// FX Vault locked (manual, idle, sleep, screen lock, main window closed).
        case locked
        /// The protocol stopped the chat (codes rejected, timeout, disconnect, verification failure).
        case aborted(NearbyAbortModel)
    }

    let reason: Reason
    /// The peer's verified name, if the codes were confirmed.
    let peerName: String?
    /// Attachments this Mac saved into its vault during the conversation (they stay there).
    let savedAttachmentCount: Int
    /// "Someone nearby may be trying to intercept this chat." (§9.4 rule, as for share).
    let showsInterceptionWarning: Bool
}

/// One line of the transcript, in order. Attachments are looked up by id because their
/// status changes.
enum ChatEntryModel: Identifiable, Equatable {
    case message(ChatMessageModel)
    case attachment(ChatAttachmentID)

    var id: String {
        switch self {
        case .message(let message): "message-\(message.id)"
        case .attachment(let id): "attachment-\(id)"
        }
    }

    var isMessage: Bool {
        if case .message = self { return true }
        return false
    }
}

/// An attachment card: names, kind and scope of one secret or variable. Never a value.
struct ChatAttachmentCardModel: Identifiable, Equatable {
    enum Status: Equatable {
        // Offered by this Mac
        /// Waiting for the other person to save or dismiss it.
        case awaitingPeer
        /// The other person saved it: the value was sent (and wiped here).
        case sent
        /// The other person dismissed it, or this Mac could no longer supply the value.
        case dismissedByPeer

        // Offered by the other Mac
        /// "Save to my vault" / "Dismiss".
        case offered
        /// Asked for the value; waiting for it.
        case requested
        /// The value arrived: review it in the import preview.
        case readyToSave
        /// The import preview is open.
        case reviewing
        /// Imported into this vault.
        case saved
        /// The preview was cancelled; the value was wiped.
        case notSaved
        /// Dismissed here.
        case dismissed
        /// The other Mac withdrew it.
        case withdrawn
    }

    let offer: ChatAttachmentOfferModel
    /// When it was offered (this Mac's clock).
    let date: Date
    var status: Status

    var id: ChatAttachmentID {
        offer.id
    }

    var direction: ChatDirection {
        offer.direction
    }

    /// "Save to my vault" and "Dismiss" are offered.
    var isAwaitingDecision: Bool {
        direction == .received && status == .offered
    }

    /// "Review…" reopens the import preview of an arrived value.
    var canReview: Bool {
        direction == .received && status == .readyToSave
    }
}

/// One group of the attachment picker: a repository level or one environment.
struct ChatPickerSectionModel: Identifiable, Equatable {
    let repositoryFullName: String
    let environmentName: String?
    let items: [ChatAttachableItemModel]

    var id: String {
        "\(repositoryFullName)/\(environmentName ?? "")"
    }
}
