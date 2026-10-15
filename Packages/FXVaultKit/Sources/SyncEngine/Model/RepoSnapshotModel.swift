import Foundation
import VaultCore

/// Everything the pure sync model knows about one repository's local desired state
/// (tasks/todo.md §7.1 `ChangeSetBuilder.build`, §7.7 `DriftDetector.detect`).
///
/// - ``repository``: `github_id` (nil = pending creation), name, visibility and create spec.
/// - ``environments``: every environment row including tombstones, each with its policy and
///   pattern rows (`DeploymentBranchPolicyModel.custom` holds tombstoned patterns too) and its
///   `synced_name`, `synced_branch_policy` and `github_env_id`.
/// - ``items``: every item row including tombstones, as fingerprints and flags.
///
/// VaultData builds it from `RepoPendingInputsModel` (repository and environments are already
/// VaultCore models; items map from `ConfigItemState`).
public struct RepoSnapshotModel: Sendable, Hashable {
    public var repository: RepoModel
    public var environments: [EnvironmentModel]
    public var items: [ConfigItemSnapshotModel]

    public init(repository: RepoModel, environments: [EnvironmentModel], items: [ConfigItemSnapshotModel]) {
        self.repository = repository
        self.environments = environments
        self.items = items
    }

    /// The environment row with `id`.
    public func environment(_ id: EnvironmentID) -> EnvironmentModel? {
        environments.first { $0.id == id }
    }

    /// Item rows in `scope` (tombstones included).
    public func items(in scope: ConfigScope) -> [ConfigItemSnapshotModel] {
        items.filter { $0.scope == scope }
    }

    /// The fold keys `EnvironmentNameValidator.checkAvailability` needs for a new or renamed
    /// environment (§7.1 editing rules): `taken` holds every other row's `name_key`, `reserved`
    /// the `synced_name_key` of every other row with a pending rename or deletion.
    ///
    /// - Parameter excluding: the environment being renamed, if any.
    public func environmentNameKeys(excluding: EnvironmentID? = nil) -> (taken: Set<String>, reserved: Set<String>) {
        var taken: Set<String> = []
        var reserved: Set<String> = []
        for environment in environments where environment.id != excluding {
            taken.insert(environment.nameKey)
            if let syncedKey = environment.syncedNameKey,
               environment.isDeleted || environment.hasPendingRename {
                reserved.insert(syncedKey)
            }
        }
        return (taken, reserved)
    }
}
