import GitHubKit
import VaultCore

/// Which repositories of the organization can use an item, as the user sets it (1.0, B6b). A
/// `selected` list is complete and validated (``GHSelectedRepositories``): Sync sends it as is.
public enum OrgItemAccessModel: Sendable, Hashable {
    case all
    case `private`
    case selected([String])

    public var visibility: OrgVisibility {
        switch self {
        case .all: .all
        case .private: .private
        case .selected: .selected
        }
    }

    /// The list to store: validated for `selected`, empty otherwise.
    func validatedRepositories() throws(ValidationError) -> [String] {
        guard case .selected(let names) = self else { return [] }
        do {
            return try GHSelectedRepositories(names).names
        } catch {
            if case .invalidInput(let validation) = error { throw validation }
            throw .invalidName(.empty)
        }
    }
}
