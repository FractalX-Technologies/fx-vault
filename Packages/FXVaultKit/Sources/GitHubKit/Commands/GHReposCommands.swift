import Foundation
import VaultCore

/// What `gh repo create` should create (tasks/todo.md §8 C1, D18).
public struct GHRepoCreateRequest: Sendable, Hashable {
    public var repo: GHRepoRef
    public var visibility: RepoVisibility
    public var description: String?
    public var addReadme: Bool
    public var gitignoreTemplate: String?
    public var licenseTemplate: String?

    public init(
        repo: GHRepoRef,
        visibility: RepoVisibility,
        description: String? = nil,
        addReadme: Bool = false,
        gitignoreTemplate: String? = nil,
        licenseTemplate: String? = nil
    ) {
        self.repo = repo
        self.visibility = visibility
        self.description = description
        self.addReadme = addReadme
        self.gitignoreTemplate = gitignoreTemplate
        self.licenseTemplate = licenseTemplate
    }
}

/// argv builders and decoders for `gh repo` (§8 B1, B2, C1). Never `--clone` (D18).
public enum GHReposCommands {
    /// B1: `gh repo list <owner> --limit <Limits.repoListMax> --json <fields>`.
    /// A result of exactly `Limits.repoListMax` repositories means the list was truncated.
    public static func list(owner: String) throws(GHError) -> GHCommand {
        let owner = try validatedOwner(owner)
        return try GHCommand(
            operation: .repoList,
            arguments: ["repo", "list", owner, "--limit", String(Limits.repoListMax), "--json", GHRepoDTO.jsonFields],
            logTemplate: "repo list {o} --limit \(Limits.repoListMax) --json <B1 fields>"
        )
    }

    /// B2: `gh repo view <O>/<R> --json <fields>`.
    public static func view(_ repo: GHRepoRef) throws(GHError) -> GHCommand {
        try GHCommand(
            operation: .repoView,
            arguments: ["repo", "view", repo.fullName, "--json", GHRepoDTO.jsonFields],
            logTemplate: "repo view {o}/{r} --json <B1 fields>"
        )
    }

    /// C1: `gh repo create <O>/<N> --private|--public|--internal [--description=<D>]
    /// [--add-readme] [--gitignore=<T>] [--license=<L>]`. Never retried (§7.3).
    public static func create(_ request: GHRepoCreateRequest) throws(GHError) -> GHCommand {
        var arguments = ["repo", "create", request.repo.fullName, visibilityFlag(request.visibility)]
        var template = "repo create {o}/{n} \(visibilityFlag(request.visibility))"
        if let description = request.description, !description.isEmpty {
            try validateFreeText(description)
            arguments.append("--description=\(description)")
            template += " --description={d}"
        }
        if request.addReadme {
            arguments.append("--add-readme")
            template += " --add-readme"
        }
        if let gitignore = request.gitignoreTemplate {
            arguments.append("--gitignore=\(try validatedTemplateName(gitignore))")
            template += " --gitignore={t}"
        }
        if let license = request.licenseTemplate {
            arguments.append("--license=\(try validatedTemplateName(license))")
            template += " --license={l}"
        }
        return try GHCommand(operation: .repoCreate, arguments: arguments, logTemplate: template)
    }

    /// Decodes B1 and wipes stdout.
    public static func decodeList(_ output: GHCommandOutput) throws(GHError) -> [GHRepoDTO] {
        defer { output.wipe() }
        return try GHJSONDecoding.decode([GHRepoDTO].self, from: output.stdout)
    }

    /// Decodes B2 and wipes stdout.
    public static func decodeView(_ output: GHCommandOutput) throws(GHError) -> GHRepoDTO {
        defer { output.wipe() }
        return try GHJSONDecoding.decode(GHRepoDTO.self, from: output.stdout)
    }

    /// Parses the one line C1 prints with non-TTY stdout, the new repository's URL
    /// (`https://github.com/<owner>/<normalized-name>`): the primary source of the name
    /// GitHub actually used (§8 C1).
    public static func decodeCreated(_ output: GHCommandOutput) throws(GHError) -> GHRepoRef {
        defer { output.wipe() }
        let text = output.stdout.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        guard let line = text.split(whereSeparator: \.isNewline).last(where: { !$0.isEmpty }) else {
            throw .malformedOutput
        }
        return try GHRepoRef(repositoryURL: String(line))
    }

    static func validatedOwner(_ owner: String) throws(GHError) -> String {
        do {
            try OwnerLoginValidator.validate(owner)
            try PathSegmentValidator.validate(owner)
        } catch {
            throw .invalidInput(error)
        }
        return owner
    }

    /// Template names (`--gitignore=`, `--license=`): non-empty, no control, bidi or
    /// zero-width characters, no surrounding whitespace.
    static func validatedTemplateName(_ name: String) throws(GHError) -> String {
        guard !name.isEmpty else { throw .invalidInput(.invalidName(.empty)) }
        try validateFreeText(name)
        guard name == name.trimmingCharacters(in: .whitespaces) else {
            throw .invalidInput(.invalidName(.leadingOrTrailingWhitespace))
        }
        return name
    }

    /// Free text in a flag value: no control, bidi or zero-width characters.
    static func validateFreeText(_ text: String) throws(GHError) {
        if let violation = UnicodeScalarPolicy.firstViolation(in: text) {
            throw .invalidInput(.invalidName(UnicodeScalarPolicy.nameRule(for: violation)))
        }
    }

    private static func visibilityFlag(_ visibility: RepoVisibility) -> String {
        switch visibility {
        case .public: "--public"
        case .private: "--private"
        case .internal: "--internal"
        }
    }
}
