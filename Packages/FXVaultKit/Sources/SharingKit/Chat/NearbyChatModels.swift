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

/// What an attachment offer holds, by names and counts only.
public enum ChatAttachmentContentModel: Sendable, Equatable {
    /// One secret or variable with a value.
    case item(kind: ConfigKind, name: String, environmentName: String?)
    /// A whole repository's or environment's configuration (v0.4.0, chat v2).
    case configuration(ChatConfigurationSummaryModel)
    /// A copy of a folder (v0.7.0, chat v4).
    case folder(ChatFolderSummaryModel)
}

/// What a folder attachment card shows (v0.7.0): the folder's name and counts.
public struct ChatFolderSummaryModel: Sendable, Equatable {
    public let name: String
    public let secretCount: Int
    public let variableCount: Int

    init(_ manifest: SharePackageModel) {
        name = manifest.folder?.name ?? ""
        secretCount = manifest.repository.secrets.count
        variableCount = manifest.repository.variables.count
    }
}

/// The counts a configuration attachment card shows (v0.4.0).
public struct ChatConfigurationSummaryModel: Sendable, Equatable {
    /// The environments, in package order.
    public let environmentNames: [String]
    public let secretCount: Int
    public let variableCount: Int
    /// Secrets the sender has no value for (GitHub never returns one): they travel by name.
    public let valueMissingCount: Int

    init(_ manifest: SharePackageModel) {
        environmentNames = manifest.repository.environments.map(\.name)
        let items = manifest.flattenedItems
        secretCount = items.filter { $0.kind == .secret }.count
        variableCount = items.filter { $0.kind == .variable }.count
        valueMissingCount = items.filter { $0.item.valueState != .present }.count
    }
}

/// An attachment offer: one secret or variable, or (v0.4.0) a whole repository's or
/// environment's configuration, described by names only. Never carries a value.
public struct ChatAttachmentOfferModel: Sendable, Equatable, Identifiable {
    public let id: ChatAttachmentID
    public let direction: ChatDirection
    public let content: ChatAttachmentContentModel
    /// `owner/name`; empty for a folder.
    public let repositoryFullName: String
    /// The offered package with every value null. The receiver can preview it with the share
    /// import planner before asking for the values.
    public let manifest: SharePackageModel

    /// Builds the card from a manifest: one item (scope `secret`) or a configuration (scope
    /// `repository` or `environment`); nil for a `secret` manifest that does not hold exactly one
    /// item. Values in `manifest` are stripped.
    public init?(id: ChatAttachmentID, direction: ChatDirection, manifest: SharePackageModel) {
        let manifest = manifest.manifest()
        switch manifest.scope {
        case .secret:
            guard let located = manifest.flattenedItems.first, manifest.itemCount == 1 else { return nil }
            content = .item(kind: located.kind, name: located.item.name, environmentName: located.environmentName)
        case .repository, .environment:
            content = .configuration(ChatConfigurationSummaryModel(manifest))
        case .folder:
            content = .folder(ChatFolderSummaryModel(manifest))
        }
        self.id = id
        self.direction = direction
        repositoryFullName = manifest.isFolder ? "" : manifest.repository.fullName
        self.manifest = manifest
    }

    /// True for a whole repository or environment (v0.4.0).
    public var isConfiguration: Bool {
        if case .configuration = content { true } else { false }
    }

    /// The folder's name for a folder copy (v0.7.0); nil otherwise.
    public var folderName: String? {
        if case .folder(let summary) = content { summary.name } else { nil }
    }

    /// The item's kind; nil for a configuration.
    public var kind: ConfigKind? {
        if case .item(let kind, _, _) = content { kind } else { nil }
    }

    /// The item's GitHub name; nil for a configuration.
    public var itemName: String? {
        if case .item(_, let name, _) = content { name } else { nil }
    }

    /// The item's environment; nil for a repository-level item and for a configuration.
    public var environmentName: String? {
        if case .item(_, _, let environmentName) = content { environmentName } else { nil }
    }

    /// The item's level (repository or environment); nil for a configuration.
    public var level: ConfigScopeLevel? {
        guard case .item(_, _, let environmentName) = content else { return nil }
        return environmentName == nil ? .repository : .environment
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
    /// The peer proved with its device key that it is this teammate (chat version 3, v0.5.0):
    /// the code counts as compared on this Mac.
    case teammateVerified(TeamCardModel)
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
    /// The requested payload, with its values as ``SecretBytes``. Validated and identical to the
    /// offer apart from the values. The caller previews and merges it through the share import
    /// planner, re-encrypts it into the vault and then calls ``SharePackageModel/wipeValues()``.
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
    /// The manifest is not one secret or variable with a value (scope `secret`) nor, in a chat
    /// v2, a configuration (scope `repository` or `environment`), or it breaks a share validator
    /// rule.
    case invalidAttachment
    /// The peer runs FX Vault 0.3 or earlier (chat v1): it cannot receive a configuration; or
    /// FX Vault 0.6 or earlier (chat v3 or below): it cannot receive a folder (v0.7.0).
    case peerNeedsUpdate
    /// ``Limits/chatMaxOpenAttachments`` offers are already open.
    case tooManyAttachments
    /// The payload is larger than ``Limits/chatAttachmentBytes``.
    case attachmentTooLarge
}

/// Supplies the value of an offered attachment when the peer asks for it. It runs only after a
/// request; the session copies the value into the payload and wipes the returned buffer.
public typealias ChatAttachmentValueProvider = @Sendable () async throws -> SecretBytes

/// Supplies the payload of an offered configuration when the peer asks for it (v0.4.0): the
/// offered manifest with its values. It runs only after a request and must return a package
/// whose manifest equals the offer; the session sends it and wipes its values.
public typealias ChatConfigurationPayloadProvider = @Sendable () async throws -> SharePackageModel
