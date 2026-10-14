import Foundation
import VaultCore

/// argv builders and decoders for `gh secret` (tasks/todo.md §8 B6/B7, C5, C6).
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
