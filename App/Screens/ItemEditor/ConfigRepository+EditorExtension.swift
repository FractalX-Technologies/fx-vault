import VaultCore
import VaultData

/// One-shot reads the editor sheets of `ItemEditor/` and `Environment/` need. Contexts carry
/// ids only (UI feature contract), so each sheet re-reads its rows when it opens.
extension ConfigRepository {
    /// The repository row as stored now.
    ///
    /// - Throws: `.repositoryNotFound` when the repository left the vault.
    func editorRepository(_ id: RepoID) throws(ConfigRepositoryError) -> RepoModel {
        guard let repository = try changeSet(repositoryID: id)?.repository else {
            throw .repositoryNotFound
        }
        return repository
    }

    /// The items of one scope as stored now (tombstones included): the first value of
    /// `observeItems`, which needs no keys.
    func editorItems(repositoryID: RepoID, scope: ConfigScope) async throws -> [ConfigItemModel] {
        for try await items in observeItems(repositoryID: repositoryID, scope: scope) {
            return items
        }
        throw ConfigRepositoryError.repositoryNotFound
    }
}
