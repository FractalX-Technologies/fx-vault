import Foundation
import VaultCore

/// Typed operations for every §8 catalog entry that runs with the account's token.
///
/// Each builds the command, runs it through the scheduler and decodes the output (wiping
/// stdout). Callers that need special 404 handling get ``GHError/notFound`` and decide
/// (tasks/todo.md §7.3: deletes count as done only after a successful re-list).
extension GHCommandScheduler {
    // MARK: - A5, B1, B2, B10

    /// A5: org logins the account is a member of.
    public func listOrganizations() async throws(GHError) -> [String] {
        GHOrgsCommands.decodeList(try await run(try GHOrgsCommands.list()))
    }

    /// B1: repositories owned by `owner`.
    public func listRepositories(owner: String) async throws(GHError) -> [GHRepoDTO] {
        try GHReposCommands.decodeList(try await run(try GHReposCommands.list(owner: owner)))
    }

    /// B2: one repository (add by name, create follow-up, reconciliation).
    public func viewRepository(_ repo: GHRepoRef) async throws(GHError) -> GHRepoDTO {
        try GHReposCommands.decodeView(try await run(try GHReposCommands.view(repo)))
    }

    /// B10: `.gitignore` template names.
    public func gitignoreTemplates() async throws(GHError) -> [String] {
        GHTemplatesCommands.decodeGitignoreList(try await run(try GHTemplatesCommands.gitignoreList()))
    }

    /// B10: license templates.
    public func licenseTemplates() async throws(GHError) -> [GHLicenseTemplateModel] {
        GHTemplatesCommands.decodeLicenseList(try await run(try GHTemplatesCommands.licenseList()))
    }

    // MARK: - C1

    /// C1: creates the repository (never retried) and returns the name gh printed.
    public func createRepository(_ request: GHRepoCreateRequest) async throws(GHError) -> GHRepoRef {
        try GHReposCommands.decodeCreated(try await run(try GHReposCommands.create(request)))
    }

    // MARK: - Environments (gh api)

    /// B3: every environment of `repo`.
    public func listEnvironments(_ repo: GHRepoRef) async throws(GHError) -> [GHEnvironmentDTO] {
        try GHEnvironmentsAPI.decodeList(try await run(try GHEnvironmentsAPI.list(repo: repo)))
    }

    /// B4: one environment, or nil when GitHub answers 404.
    public func environment(_ repo: GHRepoRef, named name: String) async throws(GHError) -> GHEnvironmentDTO? {
        do {
            let output = try await run(try GHEnvironmentsAPI.get(repo: repo, environment: name))
            return try GHEnvironmentsAPI.decodeEnvironment(output)
        } catch .notFound {
            return nil
        }
    }

    /// B11: `fxvault.yml` at the root of the default branch, or nil when the repository has none
    /// (v0.8.0).
    public func manifest(_ repo: GHRepoRef) async throws(GHError) -> GHManifestFileModel? {
        do {
            return try GHManifestAPI.decode(try await run(try GHManifestAPI.get(repo: repo)))
        } catch .notFound {
            return nil
        }
    }

    /// B5: branch policies of a custom-policy environment.
    public func listBranchPolicies(_ repo: GHRepoRef, environment: String) async throws(GHError)
        -> [GHBranchPolicyDTO]
    {
        let command = try GHEnvironmentsAPI.listBranchPolicies(repo: repo, environment: environment)
        return try GHEnvironmentsAPI.decodeBranchPolicies(try await run(command))
    }

    /// C2: creates or updates the environment's branch policy. Returns the 200 body when it
    /// decodes (confirm with B4 either way, §7.3 step 2).
    @discardableResult
    public func upsertEnvironment(
        _ repo: GHRepoRef,
        named name: String,
        branchPolicy: GitHubBranchPolicyFlagsModel?
    ) async throws(GHError) -> GHEnvironmentDTO? {
        let command = try GHEnvironmentsAPI.upsert(repo: repo, environment: name, branchPolicy: branchPolicy)
        let output = try await run(command)
        return try? GHEnvironmentsAPI.decodeEnvironment(output)
    }

    /// C3: adds a branch or tag pattern. Nil for a bare 303 (follow with B5).
    @discardableResult
    public func addBranchPolicy(
        _ repo: GHRepoRef,
        environment: String,
        pattern: String,
        type: BranchPatternType
    ) async throws(GHError) -> GHBranchPolicyDTO? {
        let command = try GHEnvironmentsAPI.addBranchPolicy(
            repo: repo,
            environment: environment,
            pattern: pattern,
            type: type
        )
        return try GHEnvironmentsAPI.decodeAddedBranchPolicy(try await run(command))
    }

    /// C4: deletes a pattern; a 404 counts as done.
    public func deleteBranchPolicy(_ repo: GHRepoRef, environment: String, policyID: Int64) async throws(GHError) {
        do {
            _ = try await run(try GHEnvironmentsAPI.deleteBranchPolicy(
                repo: repo,
                environment: environment,
                policyID: policyID
            ))
        } catch .notFound {
            return
        }
    }

    /// C9: deletes the environment. A 404 throws ``GHError/notFound``; the caller confirms
    /// with B3 before treating it as done.
    public func deleteEnvironment(_ repo: GHRepoRef, named name: String) async throws(GHError) {
        _ = try await run(try GHEnvironmentsAPI.delete(repo: repo, environment: name))
    }

    // MARK: - Secrets

    /// B6/B7.
    public func listSecrets(_ repo: GHRepoRef, environment: String? = nil) async throws(GHError) -> [GHSecretDTO] {
        try GHSecretsCommands.decodeList(try await run(try GHSecretsCommands.list(repo: repo, environment: environment)))
    }

    /// C5: `value` on stdin. The caller still wipes its own `value`.
    public func setSecret(
        _ name: String,
        repo: GHRepoRef,
        environment: String? = nil,
        value: SecretBytes
    ) async throws(GHError) {
        let command = try GHSecretsCommands.set(name: name, repo: repo, environment: environment, value: value)
        _ = try await run(command)
    }

    /// C6. A 404 throws ``GHError/notFound``; the caller confirms with B6/B7.
    public func deleteSecret(_ name: String, repo: GHRepoRef, environment: String? = nil) async throws(GHError) {
        _ = try await run(try GHSecretsCommands.delete(name: name, repo: repo, environment: environment))
    }

    // MARK: - Variables

    /// B8/B9 without 0.9's shared space marker. Each listing's value is `SecretBytes`; encrypt,
    /// then wipe it.
    public func listVariables(_ repo: GHRepoRef, environment: String? = nil) async throws(GHError)
        -> [GHVariableListingModel]
    {
        let command = try GHVariablesCommands.list(repo: repo, environment: environment)
        return GHVariablesCommands.droppingSpaceMarker(try GHVariablesCommands.decodeList(try await run(command)))
    }

    /// C7: `value` on stdin. The caller still wipes its own `value`.
    public func setVariable(
        _ name: String,
        repo: GHRepoRef,
        environment: String? = nil,
        value: SecretBytes,
        isUpdate: Bool
    ) async throws(GHError) {
        let command = try GHVariablesCommands.set(
            name: name,
            repo: repo,
            environment: environment,
            value: value,
            isUpdate: isUpdate
        )
        _ = try await run(command)
    }

    /// C8. A 404 throws ``GHError/notFound``; the caller confirms with B8/B9.
    public func deleteVariable(_ name: String, repo: GHRepoRef, environment: String? = nil) async throws(GHError) {
        _ = try await run(try GHVariablesCommands.delete(name: name, repo: repo, environment: environment))
    }
}
