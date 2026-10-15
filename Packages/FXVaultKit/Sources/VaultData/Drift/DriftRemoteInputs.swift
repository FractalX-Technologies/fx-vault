import Foundation
import GitHubKit
import SyncEngine
import VaultCore

/// Turns one full re-list (`RemoteConfigReader`: B3, B5, B6–B9) into SyncEngine's remote
/// snapshot inputs (§7.7).
///
/// A scope whose secrets **or** variables could not be read gets no listing at all, so drift
/// never mistakes an unreadable scope for one whose items were deleted. When the environment
/// list itself failed, ``environmentsListed`` is false and the caller drops every
/// environment-level finding.
struct DriftRemoteInputs {
    let repository: RemoteScopeListingInputModel?
    let environments: [RemoteEnvironmentInputModel]
    let environmentsListed: Bool

    init(_ config: RemoteRepoConfigModel) {
        var unreadableScopes: Set<String?> = []
        var unreadablePatterns: Set<String> = []
        var environmentsListed = true
        for failure in config.failures {
            switch failure.target {
            case .environments:
                environmentsListed = false
            case .branchPolicies(let environment):
                unreadablePatterns.insert(environment)
            case .secrets(let environment), .variables(let environment):
                unreadableScopes.insert(environment)
            }
        }
        repository = unreadableScopes.contains(nil)
            ? nil
            : RemoteScopeListingInputModel(secrets: config.secrets, variables: config.variables)
        environments = config.environments.map { environment in
            let isCustom = environment.listing.branchPolicyKind == .custom
            return RemoteEnvironmentInputModel(
                environment: environment.listing,
                branchPolicies: isCustom && !unreadablePatterns.contains(environment.name) ? environment.patterns : nil,
                listing: unreadableScopes.contains(environment.name)
                    ? nil
                    : RemoteScopeListingInputModel(secrets: environment.secrets, variables: environment.variables)
            )
        }
        self.environmentsListed = environmentsListed
    }
}
