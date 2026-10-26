import Foundation

/// Which repositories of an organization can use one of its secrets or variables (1.0,
/// tasks/todo.md B5). Raw values are GitHub's (`gh … list --org --json visibility`).
public enum OrgVisibility: String, Sendable, Hashable, Codable, CaseIterable {
    case all
    /// Private and internal repositories (GitHub calls it `private`).
    case `private`
    case selected
}

extension OrgVisibility {
    /// Whether GitHub gives an item of this visibility to a repository of the organization (1.0,
    /// B7a): `all` every repository, `private` the private and internal ones, `selected` the ones
    /// in `selectedRepositories` (GitHub matches repository names without case).
    public func reaches(repositoryName: String, isPrivate: Bool, selectedRepositories: [String]) -> Bool {
        switch self {
        case .all: true
        case .private: isPrivate
        case .selected: selectedRepositories.contains { $0.caseInsensitiveCompare(repositoryName) == .orderedSame }
        }
    }
}
