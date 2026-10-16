import Foundation
import GitHubKit
import SharingKit
import SyncEngine
import VaultCore
import VaultStore

/// One shared scope on GitHub, for the marker writes that happen outside Sync (genesis and
/// member changes): its binding, and the marker read and write through the account's queue.
struct SpaceMarkerTarget: Sendable {
    let binding: SpaceBindingModel
    let scheduler: GHCommandScheduler
    let ref: GHRepoRef
    /// The `--env` value; nil at repository level.
    let environmentName: String?

    /// The scope's marker, or nil when it has none.
    func listMarker() async throws(SpaceRepositoryError) -> String? {
        do {
            return try await scheduler.listVariableScope(ref, environment: environmentName).spaceMarker
        } catch {
            throw .github(error)
        }
    }

    /// Writes `marker` and re-reads it. True only when GitHub lists exactly `marker` after.
    func write(_ marker: String, isUpdate: Bool) async -> Bool {
        do {
            try await scheduler.setSpaceMarker(marker, repo: ref, environment: environmentName, isUpdate: isUpdate)
        } catch where !error.isIndeterminateOutcome {
            return false
        } catch {
            // The write may have reached GitHub: the re-read decides.
        }
        return (try? await listMarker()) == marker
    }
}

extension SpaceRepository {
    /// The scope's repository and environment on GitHub, with the account's gh queue.
    func markerTarget(repositoryID: RepoID, scope: ConfigScope) async throws(SpaceRepositoryError) -> SpaceMarkerTarget {
        let (repository, environment) = try perform {
            try session.database.read { tx in
                let repository = try RepoStore(database: session.database).fetch(id: repositoryID, in: tx)
                let environment = try scope.environmentID.flatMap { try ConfigStore(database: session.database).fetchEnvironment(id: $0, in: tx) }
                return (repository, environment)
            }
        }
        guard let repository else { throw .spaceNotFound }
        guard let githubID = repository.githubID else { throw .repositoryNotOnGitHub }
        var environmentName: String?
        if scope.environmentID != nil {
            guard let synced = environment?.syncedName else { throw .scopeNotReady }
            environmentName = synced
        }
        let scheduler: GHCommandScheduler
        let ref: GHRepoRef
        do {
            scheduler = try await schedulers.scheduler(for: repository.accountLogin)
            ref = try GHRepoRef(owner: repository.ownerLogin, name: repository.name)
        } catch {
            throw .github(error)
        }
        return SpaceMarkerTarget(
            binding: SpaceBindingModel(
                githubRepoID: githubID,
                ownerLogin: repository.ownerLogin,
                repositoryName: repository.name,
                environmentName: environmentName
            ),
            scheduler: scheduler,
            ref: ref,
            environmentName: environmentName
        )
    }
}
