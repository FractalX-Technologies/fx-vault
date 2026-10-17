import Foundation
import SharingKit
import VaultCore
import VaultCrypto
import VaultStore

/// The receiver's inputs to `ShareBundlePlanner` (v0.9.0, P7): per repository the local state
/// (snapshots and stored fingerprints, never values), GitHub's listing when one is available and
/// whether a missing repository can be imported; the vault's folders; and the keyed
/// fingerprinters that compare incoming values with local ones.
enum ProjectSharePlanning {
    /// The local state for `bundle`, read inside the caller's transaction.
    ///
    /// - Parameters:
    ///   - remotes: GitHub's listing per repository id (``ShareBundleRepositoryModel/id``).
    ///   - access: for repositories missing from the vault, whether one of this Mac's accounts can
    ///     import them (checked before the transaction; missing entries count as unknown).
    static func localState(
        for bundle: ShareBundleModel,
        database: VaultDatabase,
        tx: StoreTransaction,
        remotes: [String: ShareRemoteContextModel],
        access: [String: ShareRepositoryAccess],
        importedPackageIDs: Set<SharePackageID>,
        now: Date
    ) throws -> ShareBundleLocalStateModel {
        let config = ConfigStore(database: database)
        let destinations = DestinationStore(database: database)
        var repositories: [String: ShareBundleRepositoryStateModel] = [:]
        for entry in bundle.repositories {
            guard let local = try RepoStore(database: database).fetch(
                ownerLogin: entry.repository.owner,
                name: entry.repository.name,
                in: tx
            ) else {
                repositories[entry.id] = ShareBundleRepositoryStateModel(repository: nil, access: access[entry.id] ?? .unknown)
                continue
            }
            let localDestinations = try destinations.fetchDestinationRecords(repositoryID: local.id, in: tx).map { record in
                ShareLocalDestinationModel(
                    destination: try record.model(),
                    items: try destinations.fetchItemRecords(destinationID: record.id, in: tx).map {
                        ShareLocalDestinationItemModel(item: $0.model(), fingerprint: $0.valueFingerprint)
                    }
                )
            }
            repositories[entry.id] = ShareBundleRepositoryStateModel(
                repository: local,
                environments: try config.fetchEnvironments(repositoryID: local.id, in: tx),
                items: try config.fetchItemStates(repositoryID: local.id, in: tx).map {
                    ShareLocalItemModel(item: $0.model, fingerprint: $0.valueFingerprint)
                },
                remote: remotes[entry.id]?.snapshot,
                destinations: localDestinations
            )
        }
        let folderStore = FolderStore(database: database)
        let folders = try folderStore.fetchFolderRecords(in: tx).map { record in
            ShareLocalFolderModel(
                folder: record.model(),
                items: try folderStore.fetchItemRecords(folderID: record.id, in: tx).map {
                    ShareLocalFolderItemModel(kind: $0.kind, name: $0.name)
                }
            )
        }
        return ShareBundleLocalStateModel(
            repositories: repositories,
            folders: folders,
            importedPackageIDs: importedPackageIDs,
            now: now
        )
    }

    /// Fingerprints an incoming value for a local destination row, comparable with its `value_fp`
    /// (after D32 normalization, which is how it would be stored).
    static func destinationFingerprinter(keys: UnlockedKeys) -> ShareDestinationFingerprinter {
        { item, value in
            let normalized = ShareImportPlanning.normalizedCopy(value)
            defer { normalized.wipe() }
            return keys.fingerprint(normalized, rowID: item.id)
        }
    }

    /// `bundle` with every value in a new buffer, so the copy can be wiped independently.
    static func copyingValues(of bundle: ShareBundleModel) -> ShareBundleModel {
        func copied(_ items: [ShareItemModel]) -> [ShareItemModel] {
            items.map { item in
                var copy = item
                copy.value = item.value?.copy()
                return copy
            }
        }
        var copy = bundle
        copy.repositories = bundle.repositories.map { entry in
            var copyEntry = entry
            copyEntry.repository.secrets = copied(entry.repository.secrets)
            copyEntry.repository.variables = copied(entry.repository.variables)
            copyEntry.repository.environments = entry.repository.environments.map { environment in
                var copyEnvironment = environment
                copyEnvironment.secrets = copied(environment.secrets)
                copyEnvironment.variables = copied(environment.variables)
                return copyEnvironment
            }
            copyEntry.destinations = entry.destinations.map { destination in
                var copyDestination = destination
                copyDestination.secrets = copied(destination.secrets)
                copyDestination.variables = copied(destination.variables)
                return copyDestination
            }
            return copyEntry
        }
        copy.folders = bundle.folders.map { folder in
            var copyFolder = folder
            copyFolder.secrets = copied(folder.secrets)
            copyFolder.variables = copied(folder.variables)
            return copyFolder
        }
        return copy
    }
}
