import Foundation
import VaultCore

/// A validated `OWNER/NAME` pair (tasks/todo.md §8 conventions, D29).
///
/// The owner passes `OwnerLoginValidator`, the name `RepoNameValidator`, and both pass
/// `PathSegmentValidator`, so neither can start with `-`, contain `/`, or be a dot segment.
public struct GHRepoRef: Sendable, Hashable, CustomStringConvertible {
    public let owner: String
    public let name: String

    public init(owner: String, name: String) throws(GHError) {
        do {
            try OwnerLoginValidator.validate(owner)
            try RepoNameValidator.validate(name)
            try PathSegmentValidator.validate(owner)
            try PathSegmentValidator.validate(name)
        } catch {
            throw .invalidInput(error)
        }
        self.owner = owner
        self.name = name
    }

    /// Parses `OWNER/NAME`.
    public init(fullName: String) throws(GHError) {
        let parts = fullName.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == Self.fullNameComponentCount else {
            throw .invalidInput(.invalidPathSegment(.separator))
        }
        try self.init(owner: String(parts[0]), name: String(parts[1]))
    }

    /// Parses the URL `gh repo create` prints (`https://github.com/<owner>/<name>`, §8 C1).
    public init(repositoryURL text: String) throws(GHError) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == Self.httpsScheme,
              url.host?.lowercased() == GHConstants.host
        else { throw .malformedOutput }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == Self.fullNameComponentCount else { throw .malformedOutput }
        try self.init(owner: String(components[0]), name: String(components[1]))
    }

    /// `OWNER/NAME`.
    public var fullName: String {
        "\(owner)/\(name)"
    }

    /// `--repo=OWNER/NAME` (§5.10: user-derived flag values use the `=` form).
    public var repoFlag: String {
        "--repo=\(fullName)"
    }

    public var description: String {
        fullName
    }

    /// The comparison key (GitHub owner and repository names are case-insensitive).
    public var foldKey: String {
        "\(OwnerLoginValidator.foldKey(owner))/\(RepoNameValidator.foldKey(name))"
    }

    private static let fullNameComponentCount = 2
    private static let httpsScheme = "https"
}

/// Validated arguments shared by the secret and variable builders.
enum GHNameArguments {
    /// Validates and uppercases a secret or variable name (`^[A-Z_][A-Z0-9_]*$`).
    static func itemName(_ name: String) throws(GHError) -> String {
        do {
            return try GitHubNameValidator.validate(name)
        } catch {
            throw .invalidInput(error)
        }
    }

    /// Validates an environment name (includes `PathSegmentValidator`) and returns its NFC form.
    static func environmentName(_ name: String) throws(GHError) -> String {
        do {
            return try EnvironmentNameValidator.validate(name)
        } catch {
            throw .invalidInput(error)
        }
    }

    /// `--org=O` for a validated organization login.
    static func organizationFlag(_ organization: String) throws(GHError) -> String {
        "--org=\(try GHReposCommands.validatedOwner(organization))"
    }

    /// `[--env=E]` for an optional environment.
    static func environmentFlag(_ environment: String?) throws(GHError) -> [String] {
        guard let environment else { return [] }
        return ["--env=\(try environmentName(environment))"]
    }

    /// The `--env={e}` part of a log template.
    static func environmentTemplate(_ environment: String?) -> String {
        environment == nil ? "" : " --env={e}"
    }
}
