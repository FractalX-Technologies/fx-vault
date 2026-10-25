import Foundation
import VaultCore

/// Which repositories of an organization can use one of its secrets or variables, as an org
/// write sends it (1.0, tasks/todo.md B6).
///
/// Every org write carries one: `selected` without its repositories cannot be built, so a write
/// never falls back to gh's default visibility (`private`) or keeps GitHub's old list.
public enum GHOrgRepositoryAccess: Sendable, Hashable {
    case all
    /// Private and internal repositories (GitHub calls it `private`).
    case `private`
    case selected(GHSelectedRepositories)

    public var visibility: OrgVisibility {
        switch self {
        case .all: .all
        case .private: .private
        case .selected: .selected
        }
    }

    /// `--visibility=<v>` and, for `selected`, `--repos=<r1,r2,…>`.
    var flags: [String] {
        let visibilityFlag = "--visibility=\(visibility.rawValue)"
        guard case .selected(let repositories) = self else { return [visibilityFlag] }
        return [visibilityFlag, "--repos=\(repositories.names.joined(separator: ","))"]
    }

    /// The flags' log template: the visibility is not secret, the repository names stay out.
    var logTemplate: String {
        switch self {
        case .all, .private: " --visibility=\(visibility.rawValue)"
        case .selected: " --visibility=selected --repos={repos}"
        }
    }
}

/// The complete, non-empty list of an organization's repositories a `selected` item is shared
/// with, by name (gh prefixes the organization). gh replaces GitHub's list with this one, so a
/// partial list would revoke the missing repositories.
public struct GHSelectedRepositories: Sendable, Hashable {
    public let names: [String]

    /// Throws for an empty list, an invalid name, or a name listed twice (case-insensitive).
    public init(_ names: [String]) throws(GHError) {
        guard !names.isEmpty else { throw .invalidInput(.invalidName(.empty)) }
        var seen: Set<String> = []
        for name in names {
            do {
                try RepoNameValidator.validate(name)
                try PathSegmentValidator.validate(name)
            } catch {
                throw .invalidInput(error)
            }
            guard seen.insert(RepoNameValidator.foldKey(name)).inserted else { throw .invalidInput(.duplicateName) }
        }
        self.names = names
    }
}

/// argv shared by the organization secret and variable builders (§8 B14/B15, C10–C13).
enum GHOrgItemArguments {
    /// `<kind> set <N> --org=<O> --visibility=<v> [--repos=…]`; the value goes on stdin.
    static func set(_ kind: ConfigKind, name: String, organization: String, access: GHOrgRepositoryAccess)
        throws(GHError) -> (arguments: [String], logTemplate: String)
    {
        let name = try GHNameArguments.itemName(name)
        return (
            [kind.rawValue, "set", name, try GHNameArguments.organizationFlag(organization)] + access.flags,
            "\(kind.rawValue) set {n} --org={o}\(access.logTemplate)"
        )
    }

    /// `<kind> delete <N> --org=<O>`.
    static func delete(_ kind: ConfigKind, name: String, organization: String)
        throws(GHError) -> (arguments: [String], logTemplate: String)
    {
        let name = try GHNameArguments.itemName(name)
        return (
            [kind.rawValue, "delete", name, try GHNameArguments.organizationFlag(organization)],
            "\(kind.rawValue) delete {n} --org={o}"
        )
    }

    /// `gh api ... -X GET --paginate --slurp orgs/{o}/actions/<kind>s/{n}/repositories?per_page=100`.
    static func selectedRepositories(_ kind: ConfigKind, name: String, organization: String)
        throws(GHError) -> (arguments: [String], logTemplate: String)
    {
        let name = try GHNameArguments.itemName(name)
        let organization = try GHReposCommands.validatedOwner(organization)
        let path = try GitHubPath.orgItemRepositories(kind, organization: organization, name: name)
        return (
            GHEnvironmentsAPI.apiArguments(method: "GET", path: path, paginate: true),
            "api GET orgs/{o}/actions/\(GitHubPath.orgItemsSegment(kind))/{n}/repositories --paginate --slurp"
        )
    }

    /// Decodes B14/B15 (all pages) into repository names and wipes stdout. A count that differs
    /// from GitHub's `total_count`, or an invalid name, is malformed: a write built from a
    /// partial list would revoke the repositories that are missing.
    static func decodeSelectedRepositories(_ output: GHCommandOutput) throws(GHError) -> [String] {
        defer { output.wipe() }
        let pages = try GHJSONDecoding.decode([GHSelectedRepositoriesPageDTO].self, from: output.stdout)
        let names = pages.flatMap { $0.repositories.map(\.name) }
        guard let totalCount = pages.first?.totalCount else { throw .malformedOutput }
        guard names.count == totalCount, names.allSatisfy(RepoNameValidator.isValid) else { throw .malformedOutput }
        return names
    }
}
