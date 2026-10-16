import Foundation
import VaultCore

/// The raw JSON row of `gh variable list --json name,value,updatedAt,createdAt` (§8 B8/B9).
/// Internal: the value is moved into ``GHVariableListingModel`` immediately.
struct GHVariableDTO: Decodable {
    let name: String
    let value: String
    let updatedAt: Date?
    let createdAt: Date?

    static let jsonFields = "name,value,updatedAt,createdAt"
}

/// One listed variable. The value is in `SecretBytes`: encrypt it, then wipe it
/// (§5.12; variables are encrypted on import).
///
/// JSON decoding necessarily creates a Swift `String` of each value, which cannot be wiped;
/// that copy lives only for the duration of decoding (documented residual risk, §5.14).
public struct GHVariableListingModel: Sendable {
    public let name: String
    /// The value exactly as listed (it may end in CR/LF, D32).
    public let value: SecretBytes
    public let updatedAt: Date?
    public let createdAt: Date?

    public init(name: String, value: SecretBytes, updatedAt: Date?, createdAt: Date?) {
        self.name = name
        self.value = value
        self.updatedAt = updatedAt
        self.createdAt = createdAt
    }

    /// Wipes the value.
    public func wipe() {
        value.wipe()
    }
}

extension GHVariableListingModel: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "GHVariableListingModel(name: \(name), value: \(SecretBytes.redacted))"
    }

    public var debugDescription: String {
        description
    }
}

/// One scope's variables with the shared space marker split off (v0.6.0, S4). ``variables``
/// never contains `FXVAULT_SPACE`, so tables, drift, `.env` export and sharing never see it.
public struct GHVariableScopeListingModel: Sendable {
    public let variables: [GHVariableListingModel]
    /// `FXVAULT_SPACE`'s value (a signed JSON marker, no secret), or nil when the scope has none.
    public let spaceMarker: String?

    public init(variables: [GHVariableListingModel], spaceMarker: String?) {
        self.variables = variables
        self.spaceMarker = spaceMarker
    }
}
