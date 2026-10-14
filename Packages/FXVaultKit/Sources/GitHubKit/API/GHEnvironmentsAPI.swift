import Foundation
import VaultCore

/// `gh api` builders and decoders for environments and deployment branch policies — the only
/// `gh api` calls FX Vault makes (tasks/todo.md §8 B3–B5, C2–C4, C9; D4).
///
/// Every call: `gh api -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version:
/// 2026-03-10" -X <METHOD> <GitHubPath>`. Lists add `--paginate --slurp`; single-object reads and
/// writes add `-i`. Bodies go through `--input -` with JSON on stdin; `-f`/`-F` are never used.
public enum GHEnvironmentsAPI {
    private static let getMethod = "GET"
    private static let putMethod = "PUT"
    private static let postMethod = "POST"
    private static let deleteMethod = "DELETE"

    // MARK: - Reads

    /// B3: `gh api ... -X GET --paginate --slurp repos/{o}/{r}/environments?per_page=100`.
    public static func list(repo: GHRepoRef) throws(GHError) -> GHCommand {
        let path = try GitHubPath.environments(repo)
        return try GHCommand(
            operation: .environmentList,
            arguments: apiArguments(method: getMethod, path: path, paginate: true),
            logTemplate: "api GET repos/{o}/{r}/environments --paginate --slurp"
        )
    }

    /// B4: `gh api ... -i -X GET repos/{o}/{r}/environments/{e}`. A 404 means absent.
    public static func get(repo: GHRepoRef, environment: String) throws(GHError) -> GHCommand {
        let name = try GHNameArguments.environmentName(environment)
        let path = try GitHubPath.environment(repo, name: name)
        return try GHCommand(
            operation: .environmentGet,
            arguments: apiArguments(method: getMethod, path: path, includeHead: true),
            logTemplate: "api GET repos/{o}/{r}/environments/{e}"
        )
    }

    /// B5: `gh api ... -X GET --paginate --slurp .../deployment-branch-policies?per_page=100`.
    /// Only meaningful when the policy is custom; otherwise a 404 means none.
    public static func listBranchPolicies(repo: GHRepoRef, environment: String) throws(GHError) -> GHCommand {
        let name = try GHNameArguments.environmentName(environment)
        let path = try GitHubPath.branchPolicies(repo, environment: name, paginated: true)
        return try GHCommand(
            operation: .branchPolicyList,
            arguments: apiArguments(method: getMethod, path: path, paginate: true),
            logTemplate: "api GET repos/{o}/{r}/environments/{e}/deployment-branch-policies --paginate --slurp"
        )
    }

    // MARK: - Writes

    /// C2: `gh api ... -i -X PUT repos/{o}/{r}/environments/{e} --input -` with
    /// `{"deployment_branch_policy": null | {"protected_branches": true, "custom_branch_policies": false} | {false, true}}`.
    /// Never sends wait_timer, reviewers or prevent_self_review.
    public static func upsert(
        repo: GHRepoRef,
        environment: String,
        branchPolicy: GitHubBranchPolicyFlagsModel?
    ) throws(GHError) -> GHCommand {
        let name = try GHNameArguments.environmentName(environment)
        let path = try GitHubPath.environment(repo, name: name)
        let body = try encodeBody(EnvironmentUpsertBody(deploymentBranchPolicy: branchPolicy))
        return try GHCommand(
            operation: .environmentUpsert,
            arguments: apiArguments(method: putMethod, path: path, includeHead: true, hasInput: true),
            logTemplate: "api PUT repos/{o}/{r}/environments/{e} --input -",
            stdinValue: body
        )
    }

    /// C3: `gh api ... -i -X POST .../deployment-branch-policies --input -` with
    /// `{"name": <pattern>, "type": "branch"|"tag"}`. A 200 after gh followed GitHub's 303 (an
    /// existing pattern) and a bare 303 both count as success (§8 C3).
    public static func addBranchPolicy(
        repo: GHRepoRef,
        environment: String,
        pattern: String,
        type: BranchPatternType
    ) throws(GHError) -> GHCommand {
        let name = try GHNameArguments.environmentName(environment)
        do {
            try BranchPatternValidator.validate(pattern)
        } catch {
            throw .invalidInput(error)
        }
        let path = try GitHubPath.branchPolicies(repo, environment: name, paginated: false)
        let body = try encodeBody(BranchPolicyBody(name: pattern, type: type.rawValue))
        return try GHCommand(
            operation: .branchPolicyAdd,
            arguments: apiArguments(method: postMethod, path: path, includeHead: true, hasInput: true),
            logTemplate: "api POST repos/{o}/{r}/environments/{e}/deployment-branch-policies --input -",
            stdinValue: body
        )
    }

    /// C4: `gh api ... -i -X DELETE .../deployment-branch-policies/{id}`. 204; a 404 counts as
    /// done.
    public static func deleteBranchPolicy(
        repo: GHRepoRef,
        environment: String,
        policyID: Int64
    ) throws(GHError) -> GHCommand {
        let name = try GHNameArguments.environmentName(environment)
        let path = try GitHubPath.branchPolicy(repo, environment: name, policyID: policyID)
        return try GHCommand(
            operation: .branchPolicyDelete,
            arguments: apiArguments(method: deleteMethod, path: path, includeHead: true),
            logTemplate: "api DELETE repos/{o}/{r}/environments/{e}/deployment-branch-policies/{id}"
        )
    }

    /// C9: `gh api ... -i -X DELETE repos/{o}/{r}/environments/{e}`. 204. A 404 counts as done
    /// only when a B3 re-list succeeds and no longer shows the environment (caller's check).
    public static func delete(repo: GHRepoRef, environment: String) throws(GHError) -> GHCommand {
        let name = try GHNameArguments.environmentName(environment)
        let path = try GitHubPath.environment(repo, name: name)
        return try GHCommand(
            operation: .environmentDelete,
            arguments: apiArguments(method: deleteMethod, path: path, includeHead: true),
            logTemplate: "api DELETE repos/{o}/{r}/environments/{e}"
        )
    }

    // MARK: - Decoding

    /// Decodes B3 (all pages, flattened) and wipes stdout.
    public static func decodeList(_ output: GHCommandOutput) throws(GHError) -> [GHEnvironmentDTO] {
        defer { output.wipe() }
        let pages = try GHJSONDecoding.decode([GHEnvironmentsPageDTO].self, from: output.stdout)
        return pages.flatMap(\.environments)
    }

    /// Decodes B4 (or the body of a C2 200 response).
    public static func decodeEnvironment(_ output: GHCommandOutput) throws(GHError) -> GHEnvironmentDTO {
        guard let response = output.response, response.isSuccess else { throw .malformedOutput }
        return try GHJSONDecoding.decode(GHEnvironmentDTO.self, from: response.body)
    }

    /// Decodes B5 (all pages, flattened) and wipes stdout.
    public static func decodeBranchPolicies(_ output: GHCommandOutput) throws(GHError) -> [GHBranchPolicyDTO] {
        defer { output.wipe() }
        let pages = try GHJSONDecoding.decode([GHBranchPoliciesPageDTO].self, from: output.stdout)
        return pages.flatMap(\.branchPolicies)
    }

    /// The outcome of C3: the created (or existing) policy when the final response was a 200
    /// with a body, or nil for a bare 303 (follow with a B5 re-list).
    public static func decodeAddedBranchPolicy(_ output: GHCommandOutput) throws(GHError) -> GHBranchPolicyDTO? {
        guard let response = output.response else { throw .malformedOutput }
        if response.status == seeOther { return nil }
        guard response.isSuccess else { throw .malformedOutput }
        return try GHJSONDecoding.decode(GHBranchPolicyDTO.self, from: response.body)
    }

    private static let seeOther = 303

    // MARK: - Helpers

    static func apiArguments(
        method: String,
        path: GitHubPath,
        paginate: Bool = false,
        includeHead: Bool = false,
        hasInput: Bool = false
    ) -> [String] {
        var arguments = [
            "api",
            "-H", "Accept: \(GHConstants.acceptHeader)",
            "-H", "X-GitHub-Api-Version: \(GHConstants.apiVersion)",
            "-X", method,
        ]
        if paginate {
            arguments += ["--paginate", "--slurp"]
        }
        if includeHead {
            arguments.append("-i")
        }
        arguments.append(path.rendered)
        if hasInput {
            arguments += ["--input", "-"]
        }
        return arguments
    }

    private static func encodeBody(_ body: some Encodable) throws(GHError) -> SecretBytes {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            var data = try encoder.encode(body)
            return SecretBytes(wipingSource: &data)
        } catch {
            throw .malformedOutput
        }
    }
}

/// `{"deployment_branch_policy": null | {...}}` — `null` must be sent explicitly.
private struct EnvironmentUpsertBody: Encodable {
    let deploymentBranchPolicy: GitHubBranchPolicyFlagsModel?

    enum CodingKeys: String, CodingKey {
        case deploymentBranchPolicy = "deployment_branch_policy"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let deploymentBranchPolicy {
            try container.encode(deploymentBranchPolicy, forKey: .deploymentBranchPolicy)
        } else {
            try container.encodeNil(forKey: .deploymentBranchPolicy)
        }
    }
}

private struct BranchPolicyBody: Encodable {
    let name: String
    let type: String
}
