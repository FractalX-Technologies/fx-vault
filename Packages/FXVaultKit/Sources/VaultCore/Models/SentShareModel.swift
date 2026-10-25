import Foundation

/// How a share file is protected (`.fxvault` format 2, v0.9.0).
public enum ShareProtectionMode: String, Sendable, Hashable, CaseIterable, Codable {
    /// Argon2id over a 6-word passphrase that travels by another channel.
    case passphrase
    /// 0.9 only: sealed for paired teammates. 1.0 never writes it but still lists such rows.
    case teammates
}

/// One share file this Mac wrote (`sent_shares`, v0.9.0, P6): when, for whom and which names,
/// never values. Settings › Sharing lists these so a leaked file tells what to rotate.
public struct SentShareModel: Sendable, Hashable, Identifiable {
    public var id: SentShareID
    /// The file's `packageId`.
    public var packageID: SharePackageID
    public var createdAt: Date
    public var expiresAt: Date
    public var mode: ShareProtectionMode
    /// Lowercase device ids a 0.9 teammates file was sealed for; empty for a passphrase.
    public var recipientIDs: [String]
    public var summary: SentShareSummaryModel

    public init(
        id: SentShareID = SentShareID(),
        packageID: SharePackageID,
        createdAt: Date,
        expiresAt: Date,
        mode: ShareProtectionMode,
        recipientIDs: [String],
        summary: SentShareSummaryModel
    ) {
        self.id = id
        self.packageID = packageID
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.mode = mode
        self.recipientIDs = recipientIDs
        self.summary = summary
    }
}

/// The names a sent file carried (`sent_shares.summary`, JSON): the stages chosen and every
/// place with the names of its secrets and variables. Names are plaintext metadata in the vault,
/// as repository and item names are; values are never recorded.
public struct SentShareSummaryModel: Codable, Sendable, Hashable {
    public var stages: [String]
    public var places: [SentSharePlaceModel]

    public init(stages: [String] = [], places: [SentSharePlaceModel] = []) {
        self.stages = stages
        self.places = places
    }

    /// Every secret name in the file, the ones to rotate if it leaks.
    public var secretCount: Int {
        places.reduce(0) { $0 + $1.secretNames.count }
    }
}

/// One place inside a sent file.
public struct SentSharePlaceModel: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case repository
        case environment
        case destination
        case folder
    }

    public var kind: Kind
    /// `owner/name`; nil for a folder.
    public var repository: String?
    /// The environment's name, the destination's label or the folder's name; nil at repository
    /// level.
    public var name: String?
    public var secretNames: [String]
    public var variableNames: [String]

    public init(kind: Kind, repository: String?, name: String?, secretNames: [String], variableNames: [String]) {
        self.kind = kind
        self.repository = repository
        self.name = name
        self.secretNames = secretNames
        self.variableNames = variableNames
    }
}
