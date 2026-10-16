import Foundation
import SharingKit
import VaultCore
import VaultStore

/// "Import Into…" for a copy of a folder (v0.7.0): the folder package as a repository package
/// for one scope of a vault repository, so the usual import planner, preview and merge apply.
enum FolderPackageTargeting {
    /// `package` for `scope` of `repositoryID` (its owner, name and GitHub id; an environment
    /// scope becomes a partial environment of that name). The value buffers are shared with
    /// `package`.
    ///
    /// - Throws: `.repositoryNotFound`, `.environmentNotFound`, `.share(.invalidPackage)` when
    ///   `package` is not a folder, `.vault(.locked)`.
    static func package(
        _ package: SharePackageModel,
        into repositoryID: RepoID,
        scope: ConfigScope,
        vault: VaultSession
    ) throws(SharingError) -> SharePackageModel {
        let database = vault.database
        let (repository, environment) = try performSharing {
            try vault.read { _, tx in
                let repository = try RepoStore(database: database).fetch(id: repositoryID, in: tx)
                let environment = try scope.environmentID.flatMap { try ConfigStore(database: database).fetchEnvironment(id: $0, in: tx) }
                return (repository, environment)
            }
        }
        guard let repository else { throw .repositoryNotFound }
        if scope.environmentID != nil, environment == nil || environment?.isDeleted == true {
            throw .environmentNotFound
        }
        guard let planned = package.intoRepository(
            owner: repository.ownerLogin,
            name: repository.name,
            githubRepoID: repository.githubID,
            environmentName: environment?.name
        ) else { throw .share(.invalidPackage(.scopeMismatch(package.scope))) }
        return planned
    }
}
