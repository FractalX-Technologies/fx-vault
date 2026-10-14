import Foundation

/// One secret from `gh secret list --json name,updatedAt` (tasks/todo.md §8 B6/B7).
/// Secret values can never be read back.
public struct GHSecretDTO: Sendable, Hashable, Decodable {
    public let name: String
    public let updatedAt: Date?

    public init(name: String, updatedAt: Date?) {
        self.name = name
        self.updatedAt = updatedAt
    }

    /// The `--json` field list.
    public static let jsonFields = "name,updatedAt"
}
