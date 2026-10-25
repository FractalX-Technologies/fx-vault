import Foundation
import VaultCore

/// Builds additional authenticated data from fixed-width integers and length-prefixed fields.
///
/// `LP(x) = u32be(len(x)) ‖ x` (§5.2). Length prefixes make the encoding injective: no two
/// different field lists produce the same bytes, so one context can never be confused with
/// another by shifting bytes between neighbouring fields.
public struct AADBuilder: Sendable {
    /// The bytes appended so far.
    public private(set) var data = Data()

    public init() {}

    /// Appends one byte (`u8`).
    public mutating func append(_ byte: UInt8) {
        data.append(byte)
    }

    /// Appends `value` as 4 big-endian bytes (`u32be`).
    public mutating func append(uint32BigEndian value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    /// Appends `value` as 8 big-endian bytes (`u64be`).
    public mutating func append(uint64BigEndian value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    /// Appends `LP(bytes)`.
    ///
    /// AAD fields are ids, names and labels, so they are always far below 4 GiB; a longer field is
    /// a programming error and stops the process rather than producing an ambiguous encoding.
    public mutating func appendLengthPrefixed(_ bytes: some Collection<UInt8>) {
        guard let length = UInt32(exactly: bytes.count) else {
            preconditionFailure("AAD field longer than UInt32.max bytes")
        }
        append(uint32BigEndian: length)
        data.append(contentsOf: bytes)
    }

    /// Appends `LP(UTF-8(string))`. The string is used exactly as given (no normalization).
    public mutating func appendLengthPrefixed(_ string: String) {
        appendLengthPrefixed(string.utf8)
    }
}

/// The identity of an encrypted column that is not a configuration value (v0.5.0; since 1.0
/// only provider connection tokens). Sealed under
/// `K_field` like values, with its own label, so a blob never opens as a value or in another
/// table, column or row.
public struct SecretFieldAAD: Sendable, Hashable {
    public let table: String
    public let column: String
    /// The row's key bytes (the row id).
    public let rowKey: Data

    public init(table: String, column: String, rowKey: Data) {
        self.table = table
        self.column = column
        self.rowKey = rowKey
    }

    /// `LP("fxvault/v1/secret-field") ‖ LP(table) ‖ LP(column) ‖ LP(rowKey) ‖ u32be(dek_version)`.
    public func encoded(dekVersion: UInt32) -> Data {
        var builder = AADBuilder()
        builder.appendLengthPrefixed(CryptoDomain.secretFieldLabel)
        builder.appendLengthPrefixed(table)
        builder.appendLengthPrefixed(column)
        builder.appendLengthPrefixed(rowKey)
        builder.append(uint32BigEndian: dekVersion)
        return builder.data
    }
}

/// Which encrypted column a field blob lives in (§5.4). The table and column names are bound
/// into the AAD, so a blob copied to another column fails to decrypt.
public enum FieldLocation: Sendable, Hashable, CaseIterable {
    /// `config_items.value_ct`, bound to the item's current `name`.
    case configItemValue
    /// `config_items.synced_value_ct`, bound to the item's `synced_name`.
    case configItemSyncedValue

    /// Table name as written into the AAD.
    public var table: String {
        switch self {
        case .configItemValue, .configItemSyncedValue: "config_items"
        }
    }

    /// Column name as written into the AAD.
    public var column: String {
        switch self {
        case .configItemValue: "value_ct"
        case .configItemSyncedValue: "synced_value_ct"
        }
    }
}

/// The identity a field blob is bound to (§5.4, D11): row, repository, environment, kind and the
/// name for its column. Changing any of them (or the DEK version) makes decryption fail.
public struct FieldAAD: Sendable, Hashable {
    public let location: FieldLocation
    public let rowID: ConfigItemID
    public let repositoryID: RepoID
    /// Nil at repository level (encoded as an empty field).
    public let environmentID: EnvironmentID?
    public let kind: ConfigKind
    /// `name` for ``FieldLocation/configItemValue``, `synced_name` for
    /// ``FieldLocation/configItemSyncedValue``.
    public let name: String

    public init(
        location: FieldLocation,
        rowID: ConfigItemID,
        repositoryID: RepoID,
        environmentID: EnvironmentID?,
        kind: ConfigKind,
        name: String
    ) {
        self.location = location
        self.rowID = rowID
        self.repositoryID = repositoryID
        self.environmentID = environmentID
        self.kind = kind
        self.name = name
    }

    /// The AAD of `item.value_ct` (bound to `item.name`).
    public static func value(of item: ConfigItemModel) -> FieldAAD {
        FieldAAD(
            location: .configItemValue,
            rowID: item.id,
            repositoryID: item.repositoryID,
            environmentID: item.scope.environmentID,
            kind: item.kind,
            name: item.name
        )
    }

    /// The AAD of `item.synced_value_ct` (bound to `item.syncedName`), or nil when the item has
    /// never been synced.
    public static func syncedValue(of item: ConfigItemModel) -> FieldAAD? {
        guard let syncedName = item.syncedName else { return nil }
        return FieldAAD(
            location: .configItemSyncedValue,
            rowID: item.id,
            repositoryID: item.repositoryID,
            environmentID: item.scope.environmentID,
            kind: item.kind,
            name: syncedName
        )
    }

    /// `LP("fxvault/v1/field") ‖ LP(table) ‖ LP(column) ‖ LP(row 16B) ‖ LP(repository 16B)
    /// ‖ LP(environment 16B | empty) ‖ LP(kind) ‖ LP(name) ‖ u32be(dek_version)` (§5.4).
    public func encoded(dekVersion: UInt32) -> Data {
        Self.encode(
            table: location.table,
            column: location.column,
            row: rowID.bytes,
            container: repositoryID.bytes,
            environment: environmentID?.bytes ?? [],
            kind: kind,
            name: name,
            dekVersion: dekVersion
        )
    }

    /// The field layout shared by repository items and folder items (v0.7.0): the container is
    /// the repository or the folder, and the table name keeps the two apart.
    static func encode(
        table: String,
        column: String,
        row: [UInt8],
        container: [UInt8],
        environment: [UInt8],
        kind: ConfigKind,
        name: String,
        dekVersion: UInt32
    ) -> Data {
        var builder = AADBuilder()
        builder.appendLengthPrefixed(CryptoDomain.fieldLabel)
        builder.appendLengthPrefixed(table)
        builder.appendLengthPrefixed(column)
        builder.appendLengthPrefixed(row)
        builder.appendLengthPrefixed(container)
        builder.appendLengthPrefixed(environment)
        builder.appendLengthPrefixed(kind.rawValue)
        builder.appendLengthPrefixed(name)
        builder.append(uint32BigEndian: dekVersion)
        return builder.data
    }
}

/// The identity a folder item's value is bound to (v0.7.0, `folder_items.value_ct`): row,
/// folder, kind and name. The layout is ``FieldAAD``'s with the folder in the repository's place
/// and no environment; the table name `folder_items` keeps a folder blob from opening as a
/// repository item. Renaming the item or changing its kind re-seals the value.
public struct FolderFieldAAD: Sendable, Hashable {
    /// Table name as written into the AAD.
    public static let table = "folder_items"
    /// Column name as written into the AAD.
    public static let column = "value_ct"

    public let rowID: ConfigItemID
    public let folderID: FolderID
    public let kind: ConfigKind
    public let name: String

    public init(rowID: ConfigItemID, folderID: FolderID, kind: ConfigKind, name: String) {
        self.rowID = rowID
        self.folderID = folderID
        self.kind = kind
        self.name = name
    }

    /// `LP("fxvault/v1/field") ‖ LP("folder_items") ‖ LP("value_ct") ‖ LP(row 16B) ‖
    /// LP(folder 16B) ‖ LP(empty) ‖ LP(kind) ‖ LP(name) ‖ u32be(dek_version)`.
    public func encoded(dekVersion: UInt32) -> Data {
        FieldAAD.encode(
            table: Self.table,
            column: Self.column,
            row: rowID.bytes,
            container: folderID.bytes,
            environment: [],
            kind: kind,
            name: name,
            dekVersion: dekVersion
        )
    }
}

/// The identity a destination item's value is bound to (v0.8.0, `destination_items.value_ct`):
/// row, destination, kind and name. The layout is ``FieldAAD``'s with the destination in the
/// repository's place and no environment; the table name `destination_items` keeps a destination
/// blob from opening as a repository or folder item. Renaming the item or changing its kind
/// re-seals the value.
public struct DestinationFieldAAD: Sendable, Hashable {
    /// Table name as written into the AAD.
    public static let table = "destination_items"
    /// Column name as written into the AAD.
    public static let column = "value_ct"

    public let rowID: ConfigItemID
    public let destinationID: DestinationID
    public let kind: ConfigKind
    public let name: String

    public init(rowID: ConfigItemID, destinationID: DestinationID, kind: ConfigKind, name: String) {
        self.rowID = rowID
        self.destinationID = destinationID
        self.kind = kind
        self.name = name
    }

    /// `LP("fxvault/v1/field") ‖ LP("destination_items") ‖ LP("value_ct") ‖ LP(row 16B) ‖
    /// LP(destination 16B) ‖ LP(empty) ‖ LP(kind) ‖ LP(name) ‖ u32be(dek_version)`.
    public func encoded(dekVersion: UInt32) -> Data {
        FieldAAD.encode(
            table: Self.table,
            column: Self.column,
            row: rowID.bytes,
            container: destinationID.bytes,
            environment: [],
            kind: kind,
            name: name,
            dekVersion: dekVersion
        )
    }
}
