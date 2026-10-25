import Foundation
import VaultCore

/// argv builders and decoders for `gh variable` (tasks/todo.md §8 B8/B9, B13, B15, C7, C8, C12, C13).
///
/// Values go **only** on stdin; one command per item. `gh variable set` is an upsert (POST,
/// then PATCH on 409), so there is no create/update split; an update costs 2 writes (D12).
public enum GHVariablesCommands {
    /// B8/B9: `gh variable list --repo=<O>/<R> [--env=<E>] --json name,value,updatedAt,createdAt`.
    public static func list(repo: GHRepoRef, environment: String? = nil) throws(GHError) -> GHCommand {
        try GHCommand(
            operation: .variableList,
            arguments: ["variable", "list", repo.repoFlag]
                + (try GHNameArguments.environmentFlag(environment))
                + ["--json", GHVariableDTO.jsonFields],
            logTemplate: "variable list --repo={o}/{r}\(GHNameArguments.environmentTemplate(environment)) --json name,value,updatedAt,createdAt"
        )
    }

    /// B13: `gh variable list --org=<O> --json …,visibility,numSelectedRepos`.
    public static func list(organization: String) throws(GHError) -> GHCommand {
        try GHCommand(
            operation: .orgVariableList,
            arguments: ["variable", "list", try GHNameArguments.organizationFlag(organization), "--json", GHVariableDTO.orgJSONFields],
            logTemplate: "variable list --org={o} --json \(GHVariableDTO.orgJSONFields)"
        )
    }

    /// C7: `gh variable set <N> --repo=<O>/<R> [--env=<E>]`, `value` on stdin.
    ///
    /// `isUpdate` (the variable already exists on GitHub) only sets the throttle cost. The
    /// command keeps its own copy of `value`; the caller still wipes its buffer.
    public static func set(
        name: String,
        repo: GHRepoRef,
        environment: String? = nil,
        value: SecretBytes,
        isUpdate: Bool
    ) throws(GHError) -> GHCommand {
        let name = try GHNameArguments.itemName(name)
        try GHSecretsCommands.validateValue(value)
        return try GHCommand(
            operation: .variableSet,
            arguments: ["variable", "set", name, repo.repoFlag] + (try GHNameArguments.environmentFlag(environment)),
            logTemplate: "variable set {n} --repo={o}/{r}\(GHNameArguments.environmentTemplate(environment))",
            stdinValue: value.copy(),
            writeCost: isUpdate ? Limits.variableUpdateWriteCost : Limits.defaultWriteCost
        )
    }

    /// C8: `gh variable delete <N> --repo=<O>/<R> [--env=<E>]`.
    public static func delete(name: String, repo: GHRepoRef, environment: String? = nil) throws(GHError) -> GHCommand {
        let name = try GHNameArguments.itemName(name)
        return try GHCommand(
            operation: .variableDelete,
            arguments: ["variable", "delete", name, repo.repoFlag] + (try GHNameArguments.environmentFlag(environment)),
            logTemplate: "variable delete {n} --repo={o}/{r}\(GHNameArguments.environmentTemplate(environment))"
        )
    }

    /// B15: `gh api ... -X GET --paginate --slurp orgs/{o}/actions/variables/{n}/repositories?per_page=100`;
    /// decode with ``GHSecretsCommands/decodeSelectedRepositories(_:)``.
    public static func selectedRepositories(name: String, organization: String) throws(GHError) -> GHCommand {
        let built = try GHOrgItemArguments.selectedRepositories(.variable, name: name, organization: organization)
        return try GHCommand(operation: .orgVariableRepositories, arguments: built.arguments, logTemplate: built.logTemplate)
    }

    /// C12: `gh variable set <N> --org=<O> --visibility=<v> [--repos=<r1,r2,…>]`, `value` on
    /// stdin. An upsert like C7 (POST, then PATCH on 409), so `isUpdate` only sets the cost.
    public static func set(
        name: String,
        organization: String,
        access: GHOrgRepositoryAccess,
        value: SecretBytes,
        isUpdate: Bool
    ) throws(GHError) -> GHCommand {
        let built = try GHOrgItemArguments.set(.variable, name: name, organization: organization, access: access)
        try GHSecretsCommands.validateValue(value)
        return try GHCommand(
            operation: .orgVariableSet,
            arguments: built.arguments,
            logTemplate: built.logTemplate,
            stdinValue: value.copy(),
            writeCost: isUpdate ? Limits.variableUpdateWriteCost : Limits.defaultWriteCost
        )
    }

    /// C13: `gh variable delete <N> --org=<O>`.
    public static func delete(name: String, organization: String) throws(GHError) -> GHCommand {
        let built = try GHOrgItemArguments.delete(.variable, name: name, organization: organization)
        return try GHCommand(operation: .orgVariableDelete, arguments: built.arguments, logTemplate: built.logTemplate)
    }

    /// Every listing but `FXVAULT_SPACE`, the marker 0.9's shared spaces wrote (S4), which is
    /// wiped: repositories shared with 0.9 still carry it, and it is FX Vault's, not the user's.
    public static func droppingSpaceMarker(_ listings: [GHVariableListingModel]) -> [GHVariableListingModel] {
        listings.filter { listing in
            guard GitHubNameValidator.foldKey(listing.name) == GitHubNameValidator.spaceMarkerName else { return true }
            listing.wipe()
            return false
        }
    }

    /// Decodes B8/B9 into listings whose values are `SecretBytes`, then wipes stdout.
    public static func decodeList(_ output: GHCommandOutput) throws(GHError) -> [GHVariableListingModel] {
        defer { output.wipe() }
        let rows = try GHJSONDecoding.decode([GHVariableDTO].self, from: output.stdout)
        return rows.map { row in
            GHVariableListingModel(
                name: row.name,
                value: SecretBytes(utf8: row.value),
                updatedAt: row.updatedAt,
                createdAt: row.createdAt,
                visibility: row.visibility,
                numSelectedRepos: row.numSelectedRepos
            )
        }
    }
}
