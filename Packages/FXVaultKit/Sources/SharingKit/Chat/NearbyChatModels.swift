import Foundation
import VaultCore

/// Tag for ids of chat messages (local only, never sent).
public enum ChatMessageTag {}
/// Id of one chat message, for list identity in the UI. Generated locally on each side.
public typealias ChatMessageID = Identifier<ChatMessageTag>

/// Tag for ids of chat attachments.
public enum ChatAttachmentTag {}
/// Id of one attachment offer, chosen at random by the sender and carried in every
/// attachment frame.
public typealias ChatAttachmentID = Identifier<ChatAttachmentTag>

/// Who wrote a message or offered an attachment, seen from this Mac.
public enum ChatDirection: String, Sendable, Hashable, CaseIterable {
    case sent
    case received
}

/// Where a chat is (``NearbyChatSession/phase``).
public enum NearbyChatPhase: String, Sendable, Hashable, CaseIterable {
    /// Created, `start()` not called yet.
    case idle
    /// Started; waiting for the transport to connect. A responder waits here, with no timer,
    /// for as long as the chat window advertises.
    case awaitingPeer
    /// I: HELLO_I sent, waiting for HELLO_R. R: waiting for HELLO_I.
    case awaitingHello
    /// R: HELLO_R sent, waiting for REVEAL_I.
    case awaitingReveal
    /// Both: the code is shown; waiting for both users' confirmations.
    case comparingCodes
    /// Both users confirmed: messages and attachments may flow.
    case chatting
    /// Ended normally (either side closed a verified chat).
    case closed
    /// Ended by an abort. Final: no resume, no retry.
    case aborted

    /// Whether the chat has ended.
    public var isTerminal: Bool {
        self == .closed || self == .aborted
    }
}

/// One chat message. Lives only in memory: the session never stores messages (it forgets each
/// one once the event is delivered), and the app keeps them only while the chat window is open.
public struct ChatMessageModel: Sendable, Hashable, Identifiable {
    public let id: ChatMessageID
    public let direction: ChatDirection
    /// The sanitized text (``ChatTextSanitizer``): safe to display as is.
    public let text: String
    /// When this Mac sent or received it.
    public let date: Date

    public init(id: ChatMessageID = ChatMessageID(), direction: ChatDirection, text: String, date: Date) {
        self.id = id
        self.direction = direction
        self.text = text
        self.date = date
    }
}

/// An attachment offer: one secret or variable, described by names only. Never carries a value.
public struct ChatAttachmentOfferModel: Sendable, Equatable, Identifiable {
    public let id: ChatAttachmentID
    public let direction: ChatDirection
    public let kind: ConfigKind
    /// The item's GitHub name.
    public let itemName: String
    /// `owner/name`.
    public let repositoryFullName: String
    /// Nil for a repository-level item.
    public let environmentName: String?
    /// The offered package with every value null (scope `secret`, one item). The receiver can
    /// preview it with the share import planner before asking for the value.
    public let manifest: SharePackageModel

    /// Builds the card from a single-item manifest; nil when `manifest` does not hold exactly
    /// one item. Values in `manifest` are stripped.
    public init?(id: ChatAttachmentID, direction: ChatDirection, manifest: SharePackageModel) {
        let manifest = manifest.manifest()
        guard let located = manifest.flattenedItems.first, manifest.itemCount == 1 else { return nil }
        self.id = id
        self.direction = direction
        kind = located.kind
        itemName = located.item.name
        repositoryFullName = manifest.repository.fullName
        environmentName = located.environmentName
        self.manifest = manifest
    }

    /// Repository or environment level.
    public var level: ConfigScopeLevel {
        environmentName == nil ? .repository : .environment
    }
}

/// Something the chat UI must react to.
public enum NearbyChatEvent: Sendable, Equatable {
    /// Responder only: someone connected to this Mac's advertisement, which the listener then
    /// withdrew. Nothing is known about the peer until its HELLO (``peerConnected(name:)``); it
    /// may also drop or send garbage, which aborts this session before any code is shown.
    case incomingConnection
    /// The peer's HELLO arrived: its display name (sanitized, unverified until the codes match).
    case peerConnected(name: String)
    /// Keys exist: show the code with "Codes match" / "Don't match".
    case sasReady(NearbySASModel)
    /// The peer's user confirmed the code.
    case peerConfirmedSAS
    /// Both users confirmed: the chat is end-to-end encrypted and verified.
    case verified
    /// A message from the peer.
    case message(ChatMessageModel)
    /// The peer offers an attachment: show a card (name, kind, scope; never a value).
    case attachmentOffered(ChatAttachmentOfferModel)
    /// The peer dismissed one of this Mac's offers, or withdrew one of its own.
    case attachmentDeclined(ChatAttachmentID)
    /// This Mac's offer was requested and its payload sent.
    case attachmentSent(ChatAttachmentID)
    /// The requested payload, with its one value as ``SecretBytes``. Validated and identical to
    /// the offer apart from the value. The caller previews and merges it through the share
    /// import planner, re-encrypts it into the vault and then calls ``SharePackageModel/wipeValues()``.
    case attachmentReceived(ChatAttachmentID, SharePackageModel)
    /// The peer closed a verified chat.
    case peerClosed
    case aborted(NearbyAbortModel)
}

/// Why a chat action was refused. Typed and without text: the app maps it to a message.
public enum ChatError: Error, Sendable, Hashable {
    /// The chat ended (closed or aborted). A new chat needs a new session.
    case sessionFinished
    /// The action is not allowed in the current phase (for example sending before both users
    /// confirmed the code).
    case actionNotAllowed
    /// Nothing is left of the message after sanitizing.
    case emptyMessage
    /// The sanitized message is longer than ``Limits/chatMessageBytes``.
    case messageTooLarge
    /// No open attachment has this id, or it is not in a state that allows the action.
    case unknownAttachment
    /// The manifest is not exactly one secret or variable with a value (scope `secret`), or it
    /// breaks a share validator rule.
    case invalidAttachment
    /// ``Limits/chatMaxOpenAttachments`` offers are already open.
    case tooManyAttachments
    /// The payload is larger than ``Limits/chatAttachmentBytes``.
    case attachmentTooLarge
}

/// Supplies the value of an offered attachment when the peer asks for it. It runs only after a
/// request; the session copies the value into the payload and wipes the returned buffer.
public typealias ChatAttachmentValueProvider = @Sendable () async throws -> SecretBytes
