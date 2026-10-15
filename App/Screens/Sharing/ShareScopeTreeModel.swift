import Foundation
import VaultCore
import VaultData

/// One row of the share scope tree (§10 `ShareExportScreen`): the repository, an environment,
/// or one secret or variable. Names only, never values.
struct ShareScopeNodeModel: Identifiable, Hashable {
    enum Kind: Hashable {
        case repository
        case environment
        /// `hasValue` false: the value is missing locally and travels by name only (§7.8).
        case secret(hasValue: Bool)
        case variable
    }

    let selection: ShareSelectionModel
    let title: String
    let kind: Kind
    /// nil for items (leaves), so `OutlineGroup` shows no disclosure triangle.
    let children: [ShareScopeNodeModel]?

    var id: ShareSelectionModel {
        selection
    }
}

/// The scope tree with its checkboxes (§9.3 scopes: one secret, an environment, or the whole
/// repository configuration).
///
/// A share package holds exactly one scope, so exactly one node is checked: checking a node
/// selects it with everything under it (shown checked and dimmed), and unchecking it leaves
/// nothing selected. Nothing outside the checked subtree is ever shared.
struct ShareScopeTreeModel: Equatable {
    let root: ShareScopeNodeModel
    private(set) var selection: ShareSelectionModel?
    private let parents: [ShareSelectionModel: ShareSelectionModel]

    init(root: ShareScopeNodeModel, selection: ShareSelectionModel?) {
        self.root = root
        var parents: [ShareSelectionModel: ShareSelectionModel] = [:]
        var known: Set<ShareSelectionModel> = [root.selection]
        func walk(_ node: ShareScopeNodeModel) {
            for child in node.children ?? [] {
                parents[child.selection] = node.selection
                known.insert(child.selection)
                walk(child)
            }
        }
        walk(root)
        self.parents = parents
        self.selection = selection.flatMap { known.contains($0) ? $0 : nil }
    }

    /// The node itself is checked.
    func isSelected(_ node: ShareScopeNodeModel) -> Bool {
        node.selection == selection
    }

    /// The node is part of the share because an enclosing node is checked.
    func isIncludedByAncestor(_ node: ShareScopeNodeModel) -> Bool {
        guard let selection else { return false }
        var current = parents[node.selection]
        while let parent = current {
            if parent == selection { return true }
            current = parents[parent]
        }
        return false
    }

    /// The node is part of the share.
    func isIncluded(_ node: ShareScopeNodeModel) -> Bool {
        isSelected(node) || isIncludedByAncestor(node)
    }

    /// Checks (selects) or unchecks a node. A node included through its parent cannot be
    /// unchecked on its own (a package holds one scope): uncheck the parent, then check it.
    mutating func setChecked(_ checked: Bool, for node: ShareScopeNodeModel) {
        if checked {
            guard !isIncludedByAncestor(node) else { return }
            selection = node.selection
        } else if isSelected(node) {
            selection = nil
        }
    }

    /// Builds the tree of one repository: repository-level secrets and variables, then each
    /// environment with its items. Deleted environments and items are left out (they are never
    /// shared).
    static func build(
        repository: RepoModel,
        scopes: [ConfigScopeSummaryModel],
        items: [ConfigScope: [ConfigItemModel]],
        selection: ShareSelectionModel?
    ) -> ShareScopeTreeModel {
        func leaves(_ scope: ConfigScope) -> [ShareScopeNodeModel] {
            let live = (items[scope] ?? []).filter { !$0.isDeleted }
            let ordered = live.filter { $0.kind == .secret }.sorted(by: Self.byName)
                + live.filter { $0.kind == .variable }.sorted(by: Self.byName)
            return ordered.map { item in
                ShareScopeNodeModel(
                    selection: .item(item.id),
                    title: item.name,
                    kind: item.kind == .secret ? .secret(hasValue: item.hasValue) : .variable,
                    children: nil
                )
            }
        }
        let environments = scopes.compactMap { summary -> ShareScopeNodeModel? in
            guard let environment = summary.environment, !environment.isDeleted else { return nil }
            return ShareScopeNodeModel(
                selection: .environment(environment.id),
                title: environment.name,
                kind: .environment,
                children: leaves(summary.scope)
            )
        }
        let root = ShareScopeNodeModel(
            selection: .repository(repository.id),
            title: repository.fullName,
            kind: .repository,
            children: leaves(.repository) + environments
        )
        return ShareScopeTreeModel(root: root, selection: selection)
    }

    private static func byName(_ lhs: ConfigItemModel, _ rhs: ConfigItemModel) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

/// Reads what the scope tree shows through `ConfigRepository` (names only).
struct ShareScopeTreeLoader {
    let config: ConfigRepository
    let sharing: SharingRepository

    /// Every repository in the vault (the "what to send" picker of a nearby share).
    func repositories() async throws -> [RepoModel] {
        try await Self.first(of: config.observeRepositories()) ?? []
    }

    /// The repository a selection belongs to.
    func repositoryID(for selection: ShareSelectionModel) async throws -> RepoID {
        if case .repository(let id) = selection { return id }
        let preview = try await sharing.previewExport(selection)
        let fullName = preview.repositoryFullName.lowercased()
        guard let repository = try await repositories().first(where: { $0.fullName.lowercased() == fullName }) else {
            throw SharingError.repositoryNotFound
        }
        return repository.id
    }

    /// The tree of `repositoryID` with `selection` checked (when it is still in the vault).
    func tree(repositoryID: RepoID, selection: ShareSelectionModel?) async throws -> ShareScopeTreeModel {
        guard let repository = try await repositories().first(where: { $0.id == repositoryID }) else {
            throw SharingError.repositoryNotFound
        }
        let scopes = try config.scopes(repositoryID: repositoryID)
        var items: [ConfigScope: [ConfigItemModel]] = [:]
        for summary in scopes where summary.environment?.isDeleted != true {
            items[summary.scope] = try await Self.first(
                of: config.observeItems(repositoryID: repositoryID, scope: summary.scope)
            ) ?? []
        }
        return ShareScopeTreeModel.build(repository: repository, scopes: scopes, items: items, selection: selection)
    }

    /// The current value of an observation stream (database observations deliver it at once).
    private static func first<Value>(of stream: AsyncThrowingStream<Value, any Error>) async throws -> Value? {
        for try await value in stream {
            return value
        }
        return nil
    }
}
