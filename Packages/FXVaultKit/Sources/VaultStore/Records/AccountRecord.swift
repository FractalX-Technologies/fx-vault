import Foundation
import GRDB
import VaultCore

/// One `accounts` row (§6 `v2_accounts_repos`). `login` is unique without regard to case.
public struct AccountRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "accounts"

    public var login: String
    public var host: String
    public var sshHostAlias: String?
    public var sshVerifiedLogin: String?
    public var sshVerifiedAt: Date?
    public var isPresent: Bool
    public var lastSeenAt: Date

    public init(_ model: AccountModel) {
        login = model.login
        host = model.host
        sshHostAlias = model.sshHostAlias
        sshVerifiedLogin = model.sshVerifiedLogin
        sshVerifiedAt = model.sshVerifiedAt
        isPresent = model.isPresent
        lastSeenAt = model.lastSeenAt
    }

    /// The domain model.
    public var model: AccountModel {
        AccountModel(
            login: login,
            host: host,
            sshHostAlias: sshHostAlias,
            sshVerifiedLogin: sshVerifiedLogin,
            sshVerifiedAt: sshVerifiedAt,
            isPresent: isPresent,
            lastSeenAt: lastSeenAt
        )
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case login
        case host
        case sshHostAlias = "ssh_host_alias"
        case sshVerifiedLogin = "ssh_verified_login"
        case sshVerifiedAt = "ssh_verified_at"
        case isPresent = "is_present"
        case lastSeenAt = "last_seen_at"
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        DatabaseTimestamp.encodingStrategy
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        DatabaseTimestamp.decodingStrategy
    }
}
