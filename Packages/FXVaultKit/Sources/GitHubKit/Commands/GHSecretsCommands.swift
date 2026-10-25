import Foundation
import VaultCore

/// argv builders and decoders for `gh secret` (tasks/todo.md §8 B6/B7, B12, B14, C5, C6, C10, C11).
///
/// Values go **only** on stdin (gh reads stdin when `--body` is absent); one command per
/// item, never `--env-file`. Repository and environment use the `--repo=` / `--env=` forms.
public enum GHSecretsCommands {
    /// B6/B7: `gh secret list --repo=<O>/<R> [--env=<E>] --json name,updatedAt`.
    public static func list(repo: GHRepoRef, environment: String? = nil) throws(GHError) -> GHCommand {
        try GHCommand(
            operation: .secretList,
            arguments: ["secret", "list", repo.repoFlag]
                + (try GHNameArguments.environmentFlag(environment))
                + ["--json", GHSecretDTO.jsonFields],
            logTemplate: "secret list --repo={o}/{r}\(GHNameArguments.environmentTemplate(environment)) --json name,updatedAt"
        )
    }

    /// B12: `gh secret list --org=<O> --json name,updatedAt,visibility,numSelectedRepos`.
    public static func list(organization: String) throws(GHError) -> GHCommand {
        try GHCommand(
            operation: .orgSecretList,
            arguments: ["secret", "list", try GHNameArguments.organizationFlag(organization), "--json", GHSecretDTO.orgJSONFields],
            logTemplate: "secret list --org={o} --json \(GHSecretDTO.orgJSONFields)"
        )
    }

    /// C5: `gh secret set <N> --repo=<O>/<R> [--env=<E>]`, `value` on stdin.
    ///
    /// The command keeps its own copy of `value`; the caller still wipes its buffer.
    /// `value` must be the normalized bytes (D32), non-empty and at most `Limits.maxValueBytes`.
    public static func set(
        name: String,
        repo: GHRepoRef,
        environment: String? = nil,
        value: SecretBytes
    ) throws(GHError) -> GHCommand {
        let name = try GHNameArguments.itemName(name)
        try validateValue(value)
        return try GHCommand(
            operation: .secretSet,
            arguments: ["secret", "set", name, repo.repoFlag] + (try GHNameArguments.environmentFlag(environment)),
            logTemplate: "secret set {n} --repo={o}/{r}\(GHNameArguments.environmentTemplate(environment))",
            stdinValue: value.copy()
        )
    }

    /// C6: `gh secret delete <N> --repo=<O>/<R> [--env=<E>]`.
    public static func delete(name: String, repo: GHRepoRef, environment: String? = nil) throws(GHError) -> GHCommand {
        let name = try GHNameArguments.itemName(name)
        return try GHCommand(
            operation: .secretDelete,
            arguments: ["secret", "delete", name, repo.repoFlag] + (try GHNameArguments.environmentFlag(environment)),
            logTemplate: "secret delete {n} --repo={o}/{r}\(GHNameArguments.environmentTemplate(environment))"
        )
    }

    /// B14: `gh api ... -X GET --paginate --slurp orgs/{o}/actions/secrets/{n}/repositories?per_page=100`.
    /// Only a `selected` secret has a list (GitHub answers 409 for the others).
    public static func selectedRepositories(name: String, organization: String) throws(GHError) -> GHCommand {
        let built = try GHOrgItemArguments.selectedRepositories(.secret, name: name, organization: organization)
        return try GHCommand(operation: .orgSecretRepositories, arguments: built.arguments, logTemplate: built.logTemplate)
    }

    /// C10: `gh secret set <N> --org=<O> --visibility=<v> [--repos=<r1,r2,…>]`, `value` on stdin.
    ///
    /// The command keeps its own copy of `value`; the caller still wipes its buffer.
    public static func set(
        name: String,
        organization: String,
        access: GHOrgRepositoryAccess,
        value: SecretBytes
    ) throws(GHError) -> GHCommand {
        let built = try GHOrgItemArguments.set(.secret, name: name, organization: organization, access: access)
        try validateValue(value)
        return try GHCommand(
            operation: .orgSecretSet,
            arguments: built.arguments,
            logTemplate: built.logTemplate,
            stdinValue: value.copy()
        )
    }

    /// C11: `gh secret delete <N> --org=<O>`.
    public static func delete(name: String, organization: String) throws(GHError) -> GHCommand {
        let built = try GHOrgItemArguments.delete(.secret, name: name, organization: organization)
        return try GHCommand(operation: .orgSecretDelete, arguments: built.arguments, logTemplate: built.logTemplate)
    }

    /// Decodes B14/B15 into repository names and wipes stdout.
    public static func decodeSelectedRepositories(_ output: GHCommandOutput) throws(GHError) -> [String] {
        try GHOrgItemArguments.decodeSelectedRepositories(output)
    }

    /// Decodes B6/B7 and wipes stdout.
    public static func decodeList(_ output: GHCommandOutput) throws(GHError) -> [GHSecretDTO] {
        defer { output.wipe() }
        return try GHJSONDecoding.decode([GHSecretDTO].self, from: output.stdout)
    }

    static func validateValue(_ value: SecretBytes) throws(GHError) {
        do {
            try ValueNormalizer.validate(byteCount: value.count)
        } catch {
            throw .invalidInput(error)
        }
    }
}
