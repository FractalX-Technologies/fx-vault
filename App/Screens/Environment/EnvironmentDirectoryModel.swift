import SyncEngine
import VaultCore
import VaultData

/// A repository and its environment rows (tombstones included) as the environment sheets read
/// them when they open, plus the live name check of §7.1.
struct EnvironmentDirectoryModel {
    let repository: RepoModel
    /// Every environment row, tombstones included (they hold names, §7.1).
    let environments: [EnvironmentModel]

    /// Reads the repository and its environments now.
    static func load(
        repositoryID: RepoID,
        config: ConfigRepository
    ) throws(ConfigRepositoryError) -> EnvironmentDirectoryModel {
        let repository = try config.editorRepository(repositoryID)
        let environments = try config.scopes(repositoryID: repositoryID).compactMap(\.environment)
        return EnvironmentDirectoryModel(repository: repository, environments: environments)
    }

    func environment(_ id: EnvironmentID) -> EnvironmentModel? {
        environments.first { $0.id == id }
    }

    /// Environments, their policies and environment-level items need admin (§2 Permissions).
    var readOnlyReason: RepoCapabilityModel.ReadOnlyReason? {
        repository.capability.readOnlyReason(for: .environment)
    }

    /// The plan note applies to private repositories and to one GitHub already refused (§2).
    var showsPlanNote: Bool {
        repository.visibility.isPrivate || repository.isEnvPlanGated
    }

    /// What a name means for a new, duplicated or renamed environment (§7.1 editing rules),
    /// with the same keys `ConfigRepository` checks (`RepoSnapshotModel.environmentNameKeys`).
    func nameStatus(of name: String, for purpose: EnvironmentNamePurposeModel) -> EnvironmentNameStatusModel {
        guard !name.isEmpty else { return .empty }
        if let error = EnvironmentNameValidator.violation(in: name) {
            return .invalid(error.localizedMessage)
        }
        let normalized = EnvironmentNameValidator.normalize(name)
        let key = EnvironmentNameValidator.foldKey(normalized)
        let tombstone = environments.first { $0.isDeleted && $0.nameKey == key }
        var excluded: EnvironmentID?
        switch purpose {
        case .create:
            if tombstone != nil { return .restoresDeleted }
        case .duplicate:
            if tombstone != nil { return .reserved }
        case .rename(let id):
            guard let current = environment(id) else { return .available }
            if normalized == current.name { return .unchanged }
            if key == current.nameKey { return .available }
            excluded = id
        }
        let snapshot = RepoSnapshotModel(repository: repository, environments: environments, items: [])
        let keys = snapshot.environmentNameKeys(excluding: excluded)
        if keys.taken.contains(key) { return .taken }
        if keys.reserved.contains(key) { return .reserved }
        return .available
    }
}

/// Why a sheet checks an environment name.
enum EnvironmentNamePurposeModel: Hashable {
    case create
    case duplicate
    case rename(EnvironmentID)
}

/// The live verdict on a typed environment name (fold-key availability, §7.1).
enum EnvironmentNameStatusModel: Hashable {
    /// Nothing typed yet (no message, the primary button stays disabled).
    case empty
    /// The name breaks a rule (localized message).
    case invalid(String)
    /// Another environment uses the name, compared without case (`name_key`).
    case taken
    /// A pending rename or deletion still holds the name on GitHub.
    case reserved
    /// Free.
    case available
    /// New environment only: the name belongs to a deleted environment, which comes back with
    /// its synced items (delete then re-create = undo, §7.1).
    case restoresDeleted
    /// Rename only: the name did not change.
    case unchanged

    /// True when the primary button may run with this name.
    var isAcceptable: Bool {
        switch self {
        case .available, .restoresDeleted: true
        case .empty, .invalid, .taken, .reserved, .unchanged: false
        }
    }

    /// The note under the name field, or nil.
    var note: ConfigEditorNoteModel? {
        switch self {
        case .empty, .unchanged:
            nil
        case .invalid(let message):
            .error(message)
        case .taken:
            .error(String(
                localized: "environment.name.taken",
                defaultValue: "Another environment already uses this name. GitHub compares environment names without case."
            ))
        case .reserved:
            .error(String(
                localized: "environment.name.reserved",
                defaultValue: "A pending rename or deletion still uses this name on GitHub. Sync or revert that change first."
            ))
        case .available:
            .success(String(localized: "environment.name.available", defaultValue: "Available"))
        case .restoresDeleted:
            .info(String(
                localized: "environment.name.restores",
                defaultValue: "An environment with this name is pending deletion. Creating it restores that environment with its secrets and variables."
            ))
        }
    }
}
