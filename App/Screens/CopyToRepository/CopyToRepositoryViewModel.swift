import Foundation
import Observation
import VaultCore
import VaultData

/// One scope of the chosen repository in "Copy to Another Repository" (v0.4.1).
struct CopyTargetRowModel: Hashable, Identifiable {
    let target: ItemCopyTargetModel
    /// "Repository" or the environment's name.
    let scopeTitle: String
    /// Why the account cannot add items there, or nil.
    let readOnlyReason: RepoCapabilityModel.ReadOnlyReason?

    var id: ItemCopyTargetModel.ID {
        target.id
    }
}

/// The repositories of one account in the list.
struct CopyRepositorySectionModel: Hashable, Identifiable {
    let accountLogin: String
    let repositories: [RepoModel]

    var id: String {
        accountLogin
    }
}

/// Copy To › Another Repository… (v0.4.1, tasks/todo.md L1): every repository of the vault,
/// whatever account it belongs to, searchable by name, owner or account; choose one, then one of
/// its scopes. The copies are pending adds there, linked to their sources
/// (`ConfigRepository.copyItems`), with the same "Replace or keep?" question as a paste. The
/// items may come from a scope or, v0.7.0, a folder.
@Observable
final class CopyToRepositoryViewModel {
    private(set) var isLoaded = false
    private(set) var loadError: ErrorPresentationModel?
    private(set) var itemNames: [String] = []
    private(set) var repositories: [RepoModel] = []
    var searchText = ""
    private(set) var selectedRepositoryID: RepoID?
    private(set) var targets: [CopyTargetRowModel] = []
    var selectedTargetID: ItemCopyTargetModel.ID?
    /// The copy waiting for "Replace or keep?" (the chosen scope already has some names).
    var pendingCopy: ItemCopyRequestModel?
    /// The copy's outcome: the sheet shows it with Done and Show.
    private(set) var result: ItemCopyResultModel?
    private(set) var isCopying = false
    var alert: ErrorPresentationModel?

    @ObservationIgnored let context: CopyToRepositoryContext
    @ObservationIgnored private let dependencies: FeatureDependencies

    init(context: CopyToRepositoryContext, dependencies: FeatureDependencies) {
        self.context = context
        self.dependencies = dependencies
    }

    func load() async {
        do {
            repositories = try await Self.first(dependencies.config.observeRepositories()) ?? []
            let ids = Set(context.itemIDs)
            switch context.source {
            case .scope(let repositoryID, let scope):
                let items = try await Self.first(dependencies.config.observeItems(repositoryID: repositoryID, scope: scope)) ?? []
                itemNames = items.filter { ids.contains($0.id) && !$0.isDeleted }.map(\.name)
            case .folder(let folderID):
                itemNames = try dependencies.folders.items(folderID: folderID).filter { ids.contains($0.id) }.map(\.name)
            }
            isLoaded = true
        } catch {
            loadError = error.presentation
        }
    }

    // MARK: - List

    var subtitle: String {
        switch itemNames.count {
        case 0: ""
        case 1: String(localized: "copyTo.subtitle.one", defaultValue: "Copies \(itemNames[0]). The copy stays linked to it.")
        default: String(localized: "copyTo.subtitle.several", defaultValue: "Copies \(itemNames.count) items. Each copy stays linked to its item.")
        }
    }

    /// The repositories matching the search, grouped by account, accounts and names in order.
    var sections: [CopyRepositorySectionModel] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let matching = repositories.filter { repository in
            query.isEmpty
                || repository.fullName.localizedCaseInsensitiveContains(query)
                || repository.accountLogin.localizedCaseInsensitiveContains(query)
        }
        let grouped = Dictionary(grouping: matching, by: \.accountLogin)
        return grouped.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { login in
                CopyRepositorySectionModel(
                    accountLogin: login,
                    repositories: (grouped[login] ?? []).sorted {
                        $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
                    }
                )
            }
    }

    /// Shows the scopes of `repository` (the source scope itself is left out).
    func select(_ repository: RepoModel) {
        guard selectedRepositoryID != repository.id else { return }
        selectedRepositoryID = repository.id
        selectedTargetID = nil
        let summaries = (try? dependencies.config.scopes(repositoryID: repository.id)) ?? []
        let capability = repository.capability
        targets = summaries
            .filter { !$0.isDeleted }
            .filter { context.source != .scope(repositoryID: repository.id, scope: $0.scope) }
            .map { summary in
                let reason = capability.readOnlyReason(for: summary.scope.level)
                return CopyTargetRowModel(
                    target: ItemCopyTargetModel(
                        repositoryID: repository.id,
                        scope: summary.scope,
                        title: Self.title(repository: repository, scope: summary.title),
                        isEditable: reason == nil
                    ),
                    scopeTitle: summary.title,
                    readOnlyReason: reason
                )
            }
    }

    var selectedTarget: ItemCopyTargetModel? {
        targets.first { $0.id == selectedTargetID }?.target
    }

    // MARK: - Copy

    var canCopy: Bool {
        result == nil && !isCopying && selectedTarget?.isEditable == true && !context.itemIDs.isEmpty
    }

    /// Copies into the chosen scope, or asks "Replace or keep?" first.
    func copy() {
        guard canCopy, let target = selectedTarget else { return }
        do {
            let conflicts = try dependencies.copyConflicts(context.itemIDs, to: target.place)
            if conflicts.isEmpty {
                perform(.keep)
            } else {
                pendingCopy = ItemCopyRequestModel(ids: context.itemIDs, target: target, conflicts: conflicts)
            }
        } catch {
            alert = error.presentation
        }
    }

    func confirm(replacing: Bool) {
        guard pendingCopy != nil else { return }
        pendingCopy = nil
        perform(replacing ? .replace : .keep)
    }

    var resultNotice: String? {
        guard let result, let target = selectedTarget else { return nil }
        return result.notice(target: target.title)
    }

    /// Shows the scope the items were copied to.
    func showTarget() {
        guard let target = selectedTarget else { return }
        dependencies.actions.openPlace(target.place)
    }

    private func perform(_ conflicts: ItemCopyConflictPolicy) {
        guard let target = selectedTarget else { return }
        isCopying = true
        defer { isCopying = false }
        do {
            result = try dependencies.copyItems(context.itemIDs, to: target.place, conflicts: conflicts)
        } catch {
            alert = error.presentation
        }
    }

    // MARK: - Helpers

    static func title(repository: RepoModel, scope: String) -> String {
        String(localized: "copyTo.target.title", defaultValue: "\(repository.fullName) · \(scope)")
    }

    private static func first<Element>(_ stream: AsyncThrowingStream<Element, any Error>) async throws -> Element? {
        for try await element in stream {
            return element
        }
        return nil
    }
}
