import Foundation
import GRDB
import VaultCore

/// The single `device_identity` row (§6 `v10_teammates`): this device's id and its sealed
/// teammate keys (VaultData seals and opens `secret_ct`).
public struct DeviceIdentityRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "device_identity"
    /// The only row id.
    public static let singletonID: Int64 = 1

    public var id: Int64
    /// Lowercase hex (32 characters).
    public var deviceID: String
    /// `signingSeed ‖ agreementKey ‖ announceKey`, sealed as a secret field.
    public var secretCiphertext: Data
    public var createdAt: Date
    public var updatedAt: Date

    public init(deviceID: String, secretCiphertext: Data, createdAt: Date, updatedAt: Date) {
        id = Self.singletonID
        self.deviceID = deviceID
        self.secretCiphertext = secretCiphertext
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case deviceID = "device_id"
        case secretCiphertext = "secret_ct"
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

/// One `teammates` row (§6 `v10_teammates`).
public struct TeammateRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "teammates"

    /// Lowercase hex (32 characters).
    public var deviceID: String
    public var signingPublicKey: Data
    public var agreementPublicKey: Data
    /// The teammate's announce key, sealed as a secret field.
    public var announceCiphertext: Data
    public var login: String
    public var displayName: String
    public var macName: String
    public var pairedAt: Date
    public var lastSeenAt: Date?
    public var isMuted: Bool
    public var needsCardUpdate: Bool

    public init(
        deviceID: String,
        signingPublicKey: Data,
        agreementPublicKey: Data,
        announceCiphertext: Data,
        login: String,
        displayName: String,
        macName: String,
        pairedAt: Date,
        lastSeenAt: Date? = nil,
        isMuted: Bool = false,
        needsCardUpdate: Bool = false
    ) {
        self.deviceID = deviceID
        self.signingPublicKey = signingPublicKey
        self.agreementPublicKey = agreementPublicKey
        self.announceCiphertext = announceCiphertext
        self.login = login
        self.displayName = displayName
        self.macName = macName
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.isMuted = isMuted
        self.needsCardUpdate = needsCardUpdate
    }

    /// The row without keys.
    public var model: TeammateModel {
        TeammateModel(
            id: deviceID,
            login: login,
            displayName: displayName,
            macName: macName,
            pairedAt: pairedAt,
            lastSeenAt: lastSeenAt,
            isMuted: isMuted,
            needsCardUpdate: needsCardUpdate
        )
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case deviceID = "device_id"
        case signingPublicKey = "signing_pk"
        case agreementPublicKey = "agreement_pk"
        case announceCiphertext = "announce_ct"
        case login
        case displayName = "display_name"
        case macName = "mac_name"
        case pairedAt = "paired_at"
        case lastSeenAt = "last_seen_at"
        case isMuted = "is_muted"
        case needsCardUpdate = "needs_card_update"
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        DatabaseTimestamp.encodingStrategy
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        DatabaseTimestamp.decodingStrategy
    }
}
