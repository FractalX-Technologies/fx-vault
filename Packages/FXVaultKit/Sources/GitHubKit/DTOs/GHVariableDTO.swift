import Foundation
import VaultCore

/// The raw JSON row of `gh variable list --json name,value,updatedAt,createdAt` (§8 B8/B9), or
/// with `--org` also the visibility (B13). Internal: the value is moved into
/// ``GHVariableListingModel`` immediately.
struct GHVariableDTO: Decodable {
    let name: String
    let value: String
    let updatedAt: Date?
    let createdAt: Date?
    let visibility: OrgVisibility?
    let numSelectedRepos: Int?

    static let jsonFields = "name,value,updatedAt,createdAt"
    static let orgJSONFields = "name,value,updatedAt,createdAt,visibility,numSelectedRepos"
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
    /// Organization listings only.
    public let visibility: OrgVisibility?
    /// Organization listings only; meaningful for `.selected`.
    public let numSelectedRepos: Int?

    public init(
        name: String,
        value: SecretBytes,
        updatedAt: Date?,
        createdAt: Date?,
        visibility: OrgVisibility? = nil,
        numSelectedRepos: Int? = nil
    ) {
        self.name = name
        self.value = value
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.visibility = visibility
        self.numSelectedRepos = numSelectedRepos
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

