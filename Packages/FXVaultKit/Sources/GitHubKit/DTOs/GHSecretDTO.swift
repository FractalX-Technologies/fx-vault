import Foundation
import VaultCore

/// One secret from `gh secret list --json name,updatedAt` (tasks/todo.md §8 B6/B7), or with
/// `--org` also its visibility (B12). Secret values can never be read back.
public struct GHSecretDTO: Sendable, Hashable, Decodable {
    public let name: String
    public let updatedAt: Date?
    /// Organization listings only.
    public let visibility: OrgVisibility?
    /// Organization listings only; meaningful for `.selected`.
    public let numSelectedRepos: Int?

    public init(name: String, updatedAt: Date?, visibility: OrgVisibility? = nil, numSelectedRepos: Int? = nil) {
        self.name = name
        self.updatedAt = updatedAt
        self.visibility = visibility
        self.numSelectedRepos = numSelectedRepos
    }

    /// The `--json` field list.
    public static let jsonFields = "name,updatedAt"
    /// The `--json` field list with `--org`.
    public static let orgJSONFields = "name,updatedAt,visibility,numSelectedRepos"
}
