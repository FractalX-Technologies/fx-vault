import Foundation
import GRDB
import VaultCore

/// One `sent_shares` row (§6 `v14_project_shares`, v0.9.0): a share file this Mac wrote, with
/// names only. `recipients` and `summary` are JSON text.
public struct SentShareRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sent_shares"

    public var id: SentShareID
    public var packageID: SharePackageID
    public var createdAt: Date
    public var expiresAt: Date
    public var mode: ShareProtectionMode
    /// Lowercase device ids; empty for a passphrase file.
    public var recipients: [String]
    public var summary: SentShareSummaryModel

    public init(_ model: SentShareModel) {
        id = model.id
        packageID = model.packageID
        createdAt = model.createdAt
        expiresAt = model.expiresAt
        mode = model.mode
        recipients = model.recipientIDs
        summary = model.summary
    }

    public var model: SentShareModel {
        SentShareModel(
            id: id,
            packageID: packageID,
            createdAt: createdAt,
            expiresAt: expiresAt,
            mode: mode,
            recipientIDs: recipients,
            summary: summary
        )
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case packageID = "package_id"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case mode
        case recipients
        case summary
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        DatabaseTimestamp.encodingStrategy
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        DatabaseTimestamp.decodingStrategy
    }

    /// Sorted keys, so the stored JSON is stable.
    public static func databaseJSONEncoder(for column: String) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}
