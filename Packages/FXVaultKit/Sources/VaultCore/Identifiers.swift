import Foundation

/// A typed UUID: `Identifier<RepoModel>` and `Identifier<EnvironmentModel>` cannot be mixed up.
///
/// Decision (tasks/todo.md §3 `Identifiers.swift`): typed wrappers over `UUID` rather than plain
/// `UUID`, because the field AAD (§5.4) binds row, repository and environment ids and passing
/// the wrong one would only fail at decryption time. `Tag` is a phantom type and is never stored.
///
/// - Text form (database TEXT, JSON, logs): lowercase, hyphenated (``uuidString``), §6.
/// - Binary form (AAD): the 16 raw bytes (``bytes``), §5.4.
public struct Identifier<Tag>: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// The underlying UUID.
    public let uuid: UUID

    /// A new random identifier.
    public init() {
        uuid = UUID()
    }

    /// Wraps an existing UUID.
    public init(_ uuid: UUID) {
        self.uuid = uuid
    }

    /// Parses a hyphenated UUID string in either case. Returns nil for anything else.
    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.uuid = uuid
    }

    /// Builds an identifier from exactly 16 raw bytes. Returns nil for any other length.
    public init?(bytes: some Collection<UInt8>) {
        guard bytes.count == Self.byteCount else { return nil }
        let raw = Array(bytes)
        uuid = UUID(uuid: (
            raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
            raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]
        ))
    }

    /// Lowercase hyphenated form, as stored in the database (§6).
    public var uuidString: String {
        uuid.uuidString.lowercased()
    }

    /// The 16 raw bytes, in RFC 4122 order, as bound into the field AAD (§5.4).
    public var bytes: [UInt8] {
        withUnsafeBytes(of: uuid.uuid) { Array($0) }
    }

    public var description: String {
        uuidString
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.uuidString < rhs.uuidString
    }

    /// Bytes in a UUID.
    public static var byteCount: Int {
        MemoryLayout<uuid_t>.size
    }
}

extension Identifier: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let uuid = UUID(uuidString: text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a UUID string"
            )
        }
        self.uuid = uuid
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuidString)
    }
}

/// Primary key of a `repositories` row.
public typealias RepoID = Identifier<RepoModel>
/// Primary key of an `environments` row.
public typealias EnvironmentID = Identifier<EnvironmentModel>
/// Primary key of a `config_items` row.
public typealias ConfigItemID = Identifier<ConfigItemModel>
/// Primary key of a `deployment_branch_patterns` row.
public typealias BranchPatternID = Identifier<BranchPatternModel>
/// `packageId` of a share package (§9.3).
public typealias SharePackageID = Identifier<ShareOriginModel>
/// `run_id` of one sync run in `sync_journal`.
public typealias SyncRunID = Identifier<SyncRunTag>

/// Phantom tag for ``SyncRunID``.
public enum SyncRunTag {}
