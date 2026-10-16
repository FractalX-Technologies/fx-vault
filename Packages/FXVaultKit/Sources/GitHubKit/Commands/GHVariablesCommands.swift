import Foundation
import VaultCore

/// argv builders and decoders for `gh variable` (tasks/todo.md §8 B8/B9, C7, C8).
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

    /// C7 for the shared space marker (v0.6.0, S4): `gh variable set FXVAULT_SPACE --repo=<O>/<R>
    /// [--env=<E>]`, the marker on stdin. The only command that writes the reserved name
    /// (``GitHubNameValidator/spaceMarkerName``), which ``set(name:repo:environment:value:isUpdate:)``
    /// refuses.
    public static func setSpaceMarker(
        _ marker: String,
        repo: GHRepoRef,
        environment: String? = nil,
        isUpdate: Bool
    ) throws(GHError) -> GHCommand {
        let value = SecretBytes(utf8: marker)
        defer { value.wipe() }
        try GHSecretsCommands.validateValue(value)
        return try GHCommand(
            operation: .variableSet,
            arguments: ["variable", "set", GitHubNameValidator.spaceMarkerName, repo.repoFlag]
                + (try GHNameArguments.environmentFlag(environment)),
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

    /// B8/B9 with the shared space marker split off (S4): the marker's value, and every other
    /// variable. The marker's listing is wiped.
    public static func splitSpaceMarker(_ listings: [GHVariableListingModel]) -> GHVariableScopeListingModel {
        var variables: [GHVariableListingModel] = []
        var marker: String?
        for listing in listings {
            guard GitHubNameValidator.foldKey(listing.name) == GitHubNameValidator.spaceMarkerName else {
                variables.append(listing)
                continue
            }
            marker = listing.value.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
            listing.wipe()
        }
        return GHVariableScopeListingModel(variables: variables, spaceMarker: marker)
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
                createdAt: row.createdAt
            )
        }
    }
}
