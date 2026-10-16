import Foundation
import GRDB
import VaultCore

/// One `spaces` row (§6 `v11_spaces`): a shared scope and its verified head.
public struct SpaceRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "spaces"

    public var id: SpaceID
    public var repositoryID: RepoID
    /// Nil at repository level.
    public var environmentID: EnvironmentID?
    public var headVersion: Int64
    public var headHash: Data
    public var epoch: Int64
    /// The version this Mac claimed on GitHub, until its `published` marker is confirmed there
    /// (launch reconciliation finishes it after a crash or a failed marker write).
    public var claimedVersion: Int64?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: SpaceID,
        repositoryID: RepoID,
        scope: ConfigScope,
        headVersion: Int64,
        headHash: Data,
        epoch: Int64,
        claimedVersion: Int64? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.repositoryID = repositoryID
        environmentID = scope.environmentID
        self.headVersion = headVersion
        self.headHash = headHash
        self.epoch = epoch
        self.claimedVersion = claimedVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var scope: ConfigScope {
        ConfigScope(environmentID: environmentID)
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case repositoryID = "repository_id"
        case environmentID = "environment_id"
        case headVersion = "head_version"
        case headHash = "head_hash"
        case epoch
        case claimedVersion = "claimed_version"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        DatabaseTimestamp.encodingStrategy
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        DatabaseTimestamp.decodingStrategy
    }
}

/// One `space_keys` row: an epoch key, sealed as a secret field.
public struct SpaceKeyRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "space_keys"

    public var spaceID: SpaceID
    public var epoch: Int64
    public var keyCiphertext: Data

    public init(spaceID: SpaceID, epoch: Int64, keyCiphertext: Data) {
        self.spaceID = spaceID
        self.epoch = epoch
        self.keyCiphertext = keyCiphertext
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case spaceID = "space_id"
        case epoch
        case keyCiphertext = "key_ct"
    }
}

/// One `space_versions` row: a verified version in its wire form, plus its plain facts.
public struct SpaceVersionRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "space_versions"

    public var spaceID: SpaceID
    public var version: Int64
    /// 1 genesis, 2 publish, 3 members.
    public var kind: Int64
    /// Lowercase hex.
    public var authorDeviceID: String
    public var createdAt: Date
    public var hash: Data
    public var data: Data

    public init(spaceID: SpaceID, version: Int64, kind: Int64, authorDeviceID: String, createdAt: Date, hash: Data, data: Data) {
        self.spaceID = spaceID
        self.version = version
        self.kind = kind
        self.authorDeviceID = authorDeviceID
        self.createdAt = createdAt
        self.hash = hash
        self.data = data
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case spaceID = "space_id"
        case version
        case kind
        case authorDeviceID = "author_device_id"
        case createdAt = "created_at"
        case hash
        case data
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        DatabaseTimestamp.encodingStrategy
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        DatabaseTimestamp.decodingStrategy
    }
}

/// One `teammate_addresses` row (Q4): whether this Mac syncs spaces with a teammate outside the
/// local network, and where that teammate's Mac listens (nil: this Mac only accepts it).
public struct TeammateAddressRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "teammate_addresses"

    public var deviceID: String
    /// Set together with ``port``.
    public var host: String?
    public var port: Int64?
    /// The person allowed space sync with this teammate over the network on this Mac.
    public var allowsRemote: Bool
    public var lastConnectedAt: Date?

    public init(deviceID: String, host: String?, port: Int64?, allowsRemote: Bool, lastConnectedAt: Date? = nil) {
        self.deviceID = deviceID
        self.host = host
        self.port = port
        self.allowsRemote = allowsRemote
        self.lastConnectedAt = lastConnectedAt
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case deviceID = "device_id"
        case host
        case port
        case allowsRemote = "allows_remote"
        case lastConnectedAt = "last_connected_at"
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        DatabaseTimestamp.encodingStrategy
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        DatabaseTimestamp.decodingStrategy
    }
}
