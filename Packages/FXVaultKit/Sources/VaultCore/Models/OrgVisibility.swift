/// Which repositories of an organization can use one of its secrets or variables (1.0,
/// tasks/todo.md B5). Raw values are GitHub's (`gh … list --org --json visibility`).
public enum OrgVisibility: String, Sendable, Hashable, Codable, CaseIterable {
    case all
    /// Private and internal repositories (GitHub calls it `private`).
    case `private`
    case selected
}
