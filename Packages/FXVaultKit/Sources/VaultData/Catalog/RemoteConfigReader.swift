import Foundation
import GitHubKit
import VaultCore

/// One environment as read from GitHub for an import.
struct RemoteEnvironmentConfigModel: Sendable {
    let listing: GHEnvironmentDTO
    /// The validated NFC name.
    let name: String
    /// B5 patterns (custom policy only), validated and without duplicates.
    var patterns: [GHBranchPolicyDTO] = []
    var secrets: [GHSecretDTO] = []
    var variables: [GHVariableListingModel] = []
    /// The environment's shared space marker (v0.6.0, S4), or nil.
    var spaceMarker: String?
}

/// Everything an import stores, read with B3, B5 and B6–B9 (§8). Variable values are
/// `SecretBytes` the caller wipes with ``wipe()``.
struct RemoteRepoConfigModel: Sendable {
    var environments: [RemoteEnvironmentConfigModel] = []
    var secrets: [GHSecretDTO] = []
    var variables: [GHVariableListingModel] = []
    var failures: [ImportReadFailureModel] = []
    var skipped: [SkippedRemoteNameModel] = []
    /// The repository level's shared space marker (v0.6.0, S4), or nil.
    var spaceMarker: String?

    /// Wipes every listed variable value.
    func wipe() {
        variables.forEach { $0.wipe() }
        environments.forEach { $0.variables.forEach { $0.wipe() } }
    }
}

/// Reads one repository's environments, patterns, secrets and variables (M2 import).
///
/// A read that fails because of the viewer's rights or the repository's plan (admin required,
/// no read permission, SAML, plan-gated, not found, missing scopes) is recorded and the import
/// goes on without that scope. Any other failure (token, network, rate limit, cancellation)
/// stops the import. Names the vault cannot hold (D29) are skipped and reported.
struct RemoteConfigReader {
    let scheduler: GHCommandScheduler
    let repo: GHRepoRef

    func read() async throws(GHError) -> RemoteRepoConfigModel {
        var config = RemoteRepoConfigModel()
        do {
            try await readEnvironments(into: &config)
            config.secrets = try await secrets(environment: nil, into: &config)
            (config.variables, config.spaceMarker) = try await variables(environment: nil, into: &config)
            for index in config.environments.indices {
                let name = config.environments[index].name
                config.environments[index].secrets = try await secrets(environment: name, into: &config)
                (config.environments[index].variables, config.environments[index].spaceMarker) =
                    try await variables(environment: name, into: &config)
            }
        } catch {
            config.wipe()
            throw error
        }
        return config
    }

    /// Whether a failed read only makes one scope unreadable (the import continues).
    static func isScopeFailure(_ error: GHError) -> Bool {
        switch error {
        case .adminRequired, .writeAccessRequired, .notFound, .planGated, .missingScopes, .samlRequired: true
        default: false
        }
    }

    // MARK: - Private

    private func readEnvironments(into config: inout RemoteRepoConfigModel) async throws(GHError) {
        let listings: [GHEnvironmentDTO]
        do {
            listings = try await scheduler.listEnvironments(repo)
        } catch {
            guard Self.isScopeFailure(error) else { throw error }
            config.failures.append(ImportReadFailureModel(target: .environments, error: error))
            return
        }
        var seen: Set<String> = []
        for listing in listings {
            guard let name = try? EnvironmentNameValidator.validate(listing.name),
                  seen.insert(EnvironmentNameValidator.foldKey(name)).inserted
            else {
                config.skipped.append(SkippedRemoteNameModel(kind: .environment, environment: nil, name: listing.name))
                continue
            }
            var environment = RemoteEnvironmentConfigModel(listing: listing, name: name)
            if listing.branchPolicyKind == .custom {
                environment.patterns = try await patterns(of: name, into: &config)
            }
            config.environments.append(environment)
        }
    }

    private func patterns(of environment: String, into config: inout RemoteRepoConfigModel) async throws(GHError)
        -> [GHBranchPolicyDTO]
    {
        let listed: [GHBranchPolicyDTO]
        do {
            listed = try await scheduler.listBranchPolicies(repo, environment: environment)
        } catch {
            guard Self.isScopeFailure(error) else { throw error }
            config.failures.append(ImportReadFailureModel(target: .branchPolicies(environment: environment), error: error))
            return []
        }
        var seen: Set<String> = []
        var result: [GHBranchPolicyDTO] = []
        for policy in listed {
            guard BranchPatternValidator.isValid(policy.name),
                  seen.insert("\(policy.type.rawValue)|\(policy.name)").inserted
            else {
                config.skipped.append(SkippedRemoteNameModel(kind: .branchPattern, environment: environment, name: policy.name))
                continue
            }
            result.append(policy)
        }
        return result
    }

    private func secrets(environment: String?, into config: inout RemoteRepoConfigModel) async throws(GHError)
        -> [GHSecretDTO]
    {
        let listed: [GHSecretDTO]
        do {
            listed = try await scheduler.listSecrets(repo, environment: environment)
        } catch {
            guard Self.isScopeFailure(error) else { throw error }
            config.failures.append(ImportReadFailureModel(target: .secrets(environment: environment), error: error))
            return []
        }
        var seen: Set<String> = []
        var result: [GHSecretDTO] = []
        for secret in listed {
            guard let name = try? GitHubNameValidator.validate(secret.name), seen.insert(name).inserted else {
                config.skipped.append(SkippedRemoteNameModel(kind: .item(.secret), environment: environment, name: secret.name))
                continue
            }
            result.append(GHSecretDTO(name: name, updatedAt: secret.updatedAt))
        }
        return result
    }

    /// The scope's variables (the shared space marker split off, S4) and its marker.
    private func variables(environment: String?, into config: inout RemoteRepoConfigModel) async throws(GHError)
        -> ([GHVariableListingModel], String?)
    {
        let listed: [GHVariableListingModel]
        let marker: String?
        do {
            let scope = try await scheduler.listVariableScope(repo, environment: environment)
            listed = scope.variables
            marker = scope.spaceMarker
        } catch {
            guard Self.isScopeFailure(error) else { throw error }
            config.failures.append(ImportReadFailureModel(target: .variables(environment: environment), error: error))
            return ([], nil)
        }
        var seen: Set<String> = []
        var result: [GHVariableListingModel] = []
        for variable in listed {
            guard let name = try? GitHubNameValidator.validate(variable.name), seen.insert(name).inserted else {
                config.skipped.append(SkippedRemoteNameModel(kind: .item(.variable), environment: environment, name: variable.name))
                variable.wipe()
                continue
            }
            result.append(GHVariableListingModel(
                name: name,
                value: variable.value,
                updatedAt: variable.updatedAt,
                createdAt: variable.createdAt
            ))
        }
        return (result, marker)
    }
}
