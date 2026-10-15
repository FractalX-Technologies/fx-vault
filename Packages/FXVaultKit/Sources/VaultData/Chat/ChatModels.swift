import Foundation
import SharingKit
import VaultCore

/// One secret or variable that can be attached to a nearby chat: a live item with a value.
/// Names only; the value is decrypted only when the peer asks for it
/// (``NearbyChatConversation/offerItem(_:senderName:appVersion:authorization:)``).
public struct ChatAttachableItemModel: Sendable, Hashable, Identifiable {
    public let id: ConfigItemID
    public let repositoryID: RepoID
    public let kind: ConfigKind
    public let name: String
    /// `owner/name`.
    public let repositoryFullName: String
    /// Nil for a repository-level item.
    public let environmentName: String?

    public init(
        id: ConfigItemID,
        repositoryID: RepoID,
        kind: ConfigKind,
        name: String,
        repositoryFullName: String,
        environmentName: String?
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.kind = kind
        self.name = name
        self.repositoryFullName = repositoryFullName
        self.environmentName = environmentName
    }
}

/// A repository whose whole configuration can be attached to a nearby chat (v0.4.0): names and
/// counts only; the values are decrypted only when the peer asks for them
/// (``NearbyChatConversation/offerRepository(_:senderName:appVersion:authorization:)``).
public struct ChatAttachableRepositoryModel: Sendable, Hashable, Identifiable {
    public let id: RepoID
    /// `owner/name`.
    public let fullName: String
    /// Environments that are not deleted.
    public let environmentCount: Int
    /// Secrets and variables that are not deleted, values or not.
    public let itemCount: Int

    public init(id: RepoID, fullName: String, environmentCount: Int, itemCount: Int) {
        self.id = id
        self.fullName = fullName
        self.environmentCount = environmentCount
        self.itemCount = itemCount
    }
}

/// Why a nearby chat action failed. Typed and without text: the app maps it to a message.
public enum NearbyChatError: Error, Sendable, Hashable {
    /// The chat session refused (phase, size, unknown attachment, ...).
    case chat(ChatError)
    /// Building the offer or planning the received package failed (authorization, item gone,
    /// vault locked, invalid package, ...).
    case sharing(SharingError)
    /// The item has no value to send (a secret whose value is missing locally).
    case valueMissing
    /// The attachment's value has not arrived, or it was already previewed or wiped.
    case attachmentUnavailable
}
