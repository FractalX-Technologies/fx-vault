import Foundation
import SharingKit
import VaultCore
import VaultData

/// Identity of a row in the share scope tree.
enum ShareScopeNodeID: Hashable {
    /// The root: the whole repository configuration.
    case repository(RepoID)
    /// The "Repository level" group: the repository's own secrets and variables.
    case repositoryLevel(RepoID)
    case environment(EnvironmentID)
    /// A runtime destination of the repository (project shares, v0.9.0).
    case destination(DestinationID)
    /// A folder, shared whole (project shares, v0.9.0).
    case folder(FolderID)
    case item(ConfigItemID)
}

/// One row of the share scope tree (`ProjectShareScreen`): the repository, the repository
/// level group, an environment, or one secret or variable. Names only, never values.
struct ShareScopeNodeModel: Identifiable, Hashable {
    enum Kind: Hashable {
        case repository
        /// The repository's own secrets and variables (not in an environment).
        case repositoryLevel
        case environment
        /// A runtime destination (v0.9.0), with its provider's symbol.
        case destination(symbolName: String)
        /// A folder (v0.9.0), shared whole.
        case folder
        /// `hasValue` false: the value is missing locally and travels by name only (§7.8).
        case secret(hasValue: Bool)
        case variable
    }

    let id: ShareScopeNodeID
    let title: String
    let kind: Kind
    /// nil for leaves (items, and environments without items), so the tree shows no
    /// disclosure triangle.
    let children: [ShareScopeNodeModel]?

    /// Secrets and variables under the row (the tree's counts column, board Share-Pick).
    var itemCounts: ShareItemCountModel {
        switch kind {
        case .secret: ShareItemCountModel(secrets: 1, variables: 0)
        case .variable: ShareItemCountModel(secrets: 0, variables: 1)
        default: .sum((children ?? []).map(\.itemCounts))
        }
    }

    /// A production environment: tagged, and confirmed when the file is created.
    var isProduction: Bool {
        kind == .environment && StageRisk.isProduction(title)
    }
}

/// A tree of checkable rows, as ``ShareScopeTreeView`` shows it: one or more roots and the
/// state of each row.
protocol ShareCheckTree {
    var roots: [ShareScopeNodeModel] { get }
    func state(of node: ShareScopeNodeModel) -> ShareCheckState
}

/// A tri-state checkbox.
enum ShareCheckState: Equatable {
    case unchecked
    /// Some, not all, of the rows under it are checked.
    case mixed
    case checked
}

/// The multi-select scope tree with tri-state checkboxes ("Share any combination", v0.2.0).
///
/// The state is the set of checked **leaves**: every secret and variable, plus each environment
/// that has no items (it can still be shared for its branch policy). A parent is checked when
/// every leaf under it is, mixed when some are, unchecked when none are. Checking an unchecked
/// or mixed row checks everything under it; checking a checked row unchecks everything under
/// it. Any combination is possible: the repository level only, one or more environments, the
/// repository level plus environments, or single items.
///
/// **Branch policy rule:** an environment's deployment branch policy is shared only when the
/// environment row itself is checked (checked directly, or every one of its items is checked).
/// A mixed environment shares only its checked items (a partial environment, schema v2).
/// ``selection`` encodes exactly that for `SharingRepository`. One exception: a tree opened for
/// one item ("Share this secret…") shares that item alone until the checks change, even when it
/// is its environment's only item (which would otherwise share the environment and its policy).
struct ShareScopeTreeModel: Equatable, ShareCheckTree {
    let root: ShareScopeNodeModel
    let repositoryID: RepoID
    private(set) var checkedLeaves: Set<ShareScopeNodeID>
    /// Every node's leaves (a leaf's set is itself).
    private let leaves: [ShareScopeNodeID: Set<ShareScopeNodeID>]
    /// Environments in tree order, with their leaves.
    private let environmentIDs: [EnvironmentID]
    /// The item the tree was opened for (`.item` selection), until the checks change.
    private var openedItem: ConfigItemID?

    init(root: ShareScopeNodeModel, repositoryID: RepoID, selection: ShareSelectionModel?) {
        self.root = root
        self.repositoryID = repositoryID
        var leaves: [ShareScopeNodeID: Set<ShareScopeNodeID>] = [:]
        var environmentIDs: [EnvironmentID] = []
        @discardableResult
        func collect(_ node: ShareScopeNodeModel) -> Set<ShareScopeNodeID> {
            if case .environment(let id) = node.id {
                environmentIDs.append(id)
            }
            let children = node.children ?? []
            let under = children.isEmpty
                ? (Self.isLeafCandidate(node) ? [node.id] : [])
                : children.reduce(into: Set<ShareScopeNodeID>()) { $0.formUnion(collect($1)) }
            leaves[node.id] = under
            return under
        }
        collect(root)
        self.leaves = leaves
        self.environmentIDs = environmentIDs
        checkedLeaves = []
        checkedLeaves = initialLeaves(for: selection)
        if case .item(let id) = selection, checkedLeaves == [.item(id)] {
            openedItem = id
        }
    }

    /// Items and environments can be leaves; an empty repository or repository-level group
    /// cannot (there is nothing to share).
    static func isLeafCandidate(_ node: ShareScopeNodeModel) -> Bool {
        switch node.kind {
        case .environment, .destination, .folder, .secret, .variable: true
        case .repository, .repositoryLevel: false
        }
    }

    // MARK: - State

    var roots: [ShareScopeNodeModel] {
        [root]
    }

    /// The checkbox state of `node`.
    func state(of node: ShareScopeNodeModel) -> ShareCheckState {
        state(of: node.id)
    }

    func state(of id: ShareScopeNodeID) -> ShareCheckState {
        let under = leaves[id] ?? []
        guard !under.isEmpty else { return .unchecked }
        let checked = under.intersection(checkedLeaves).count
        if checked == 0 { return .unchecked }
        return checked == under.count ? .checked : .mixed
    }

    /// Checks (`true`) or unchecks everything under `node`.
    mutating func setChecked(_ checked: Bool, for node: ShareScopeNodeModel) {
        openedItem = nil
        let under = leaves[node.id] ?? []
        if checked {
            checkedLeaves.formUnion(under)
        } else {
            checkedLeaves.subtract(under)
        }
    }

    /// A click on the checkbox: a checked row unchecks, an unchecked or mixed row checks.
    mutating func toggle(_ node: ShareScopeNodeModel) {
        setChecked(state(of: node) != .checked, for: node)
    }

    /// Nothing is checked.
    var isEmpty: Bool {
        checkedLeaves.isEmpty
    }

    // MARK: - Selection

    /// What the checked rows share, in the narrowest form: the whole repository, one whole
    /// environment, one item, or a subset (whole environments plus individual items). Nil when
    /// nothing is checked.
    var selection: ShareSelectionModel? {
        guard !checkedLeaves.isEmpty else { return nil }
        if let openedItem { return .item(openedItem) }
        if state(of: root) == .checked { return .repository(repositoryID) }
        let whole = environmentIDs.filter { state(of: .environment($0)) == .checked }
        let covered = whole.reduce(into: Set<ShareScopeNodeID>()) { $0.formUnion(leaves[.environment($1)] ?? []) }
        let items = Set(checkedLeaves.subtracting(covered).compactMap { id -> ConfigItemID? in
            if case .item(let itemID) = id { return itemID }
            return nil
        })
        if whole.count == 1, items.isEmpty, let environment = whole.first {
            return .environment(environment)
        }
        if whole.isEmpty, items.count == 1, let item = items.first {
            return .item(item)
        }
        return .subset(ShareSubsetModel(repositoryID: repositoryID, environmentIDs: Set(whole), itemIDs: items))
    }

    /// The leaves a selection covers (ids no longer in the tree are ignored).
    private func initialLeaves(for selection: ShareSelectionModel?) -> Set<ShareScopeNodeID> {
        switch selection {
        case nil:
            return []
        case .repository(let id):
            return id == repositoryID ? leaves[root.id] ?? [] : []
        case .environment(let id):
            return leaves[.environment(id)] ?? []
        case .item(let id):
            return leaves[.item(id)] ?? []
        case .subset(let subset):
            guard subset.repositoryID == repositoryID else { return [] }
            let environments = subset.environmentIDs.compactMap { leaves[.environment($0)] }
            let items = subset.itemIDs.compactMap { leaves[.item($0)] }
            return (environments + items).reduce(into: []) { $0.formUnion($1) }
        case .folder:
            // A folder is shared whole, without the scope tree (v0.7.0).
            return []
        }
    }

    // MARK: - Building

    /// Builds the tree of one repository: the "Repository level" group (left out when the
    /// repository has no items of its own), then each environment with its items. Deleted
    /// environments and items are left out (they are never shared).
    static func build(
        repository: RepoModel,
        scopes: [ConfigScopeSummaryModel],
        items: [ConfigScope: [ConfigItemModel]],
        selection: ShareSelectionModel?
    ) -> ShareScopeTreeModel {
        let root = repositoryNode(repository: repository, scopes: scopes, items: items, destinations: [])
        return ShareScopeTreeModel(root: root, repositoryID: repository.id, selection: selection)
    }

    /// The node of one repository: the "Repository level" group (left out when the repository
    /// has no items of its own), each environment with its items, then each destination with its
    /// items (project shares, v0.9.0). Deleted environments and items are left out.
    static func repositoryNode(
        repository: RepoModel,
        scopes: [ConfigScopeSummaryModel],
        items: [ConfigScope: [ConfigItemModel]],
        destinations: [(destination: DestinationModel, items: [DestinationItemModel])]
    ) -> ShareScopeNodeModel {
        func leaves(_ scope: ConfigScope) -> [ShareScopeNodeModel] {
            itemNodes((items[scope] ?? []).filter { !$0.isDeleted }.map {
                (id: $0.id, kind: $0.kind, name: $0.name, hasValue: $0.hasValue)
            })
        }
        let environments = scopes.compactMap { summary -> ShareScopeNodeModel? in
            guard let environment = summary.environment, !environment.isDeleted else { return nil }
            let children = leaves(summary.scope)
            return ShareScopeNodeModel(
                id: .environment(environment.id),
                title: environment.name,
                kind: .environment,
                children: children.isEmpty ? nil : children
            )
        }
        let runtime = destinations.map { entry -> ShareScopeNodeModel in
            let children = itemNodes(entry.items.filter { !$0.isDeleted }.map {
                (id: $0.id, kind: $0.kind, name: $0.name, hasValue: $0.hasValue)
            })
            return ShareScopeNodeModel(
                id: .destination(entry.destination.id),
                title: "\(entry.destination.provider.shortTitle) · \(entry.destination.title)",
                kind: .destination(symbolName: entry.destination.provider.symbolName),
                children: children.isEmpty ? nil : children
            )
        }
        let repositoryItems = leaves(.repository)
        let repositoryLevel = repositoryItems.isEmpty ? [] : [
            ShareScopeNodeModel(
                id: .repositoryLevel(repository.id),
                title: String(localized: "share.tree.repositoryLevel", defaultValue: "Repository level"),
                kind: .repositoryLevel,
                children: repositoryItems
            ),
        ]
        return ShareScopeNodeModel(
            id: .repository(repository.id),
            title: repository.fullName,
            kind: .repository,
            children: repositoryLevel + environments + runtime
        )
    }

    /// Secrets first, then variables, each by name.
    private static func itemNodes(
        _ items: [(id: ConfigItemID, kind: ConfigKind, name: String, hasValue: Bool)]
    ) -> [ShareScopeNodeModel] {
        func byName(_ lhs: (id: ConfigItemID, kind: ConfigKind, name: String, hasValue: Bool), _ rhs: (id: ConfigItemID, kind: ConfigKind, name: String, hasValue: Bool)) -> Bool {
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let ordered = items.filter { $0.kind == .secret }.sorted(by: byName)
            + items.filter { $0.kind == .variable }.sorted(by: byName)
        return ordered.map { item in
            ShareScopeNodeModel(
                id: .item(item.id),
                title: item.name,
                kind: item.kind == .secret ? .secret(hasValue: item.hasValue) : .variable,
                children: nil
            )
        }
    }
}

/// Reads what the scope tree shows through `ConfigRepository` (names only).
struct ShareScopeTreeLoader {
    let config: ConfigRepository
    let sharing: SharingRepository

    /// Every repository in the vault.
    func repositories() async throws -> [RepoModel] {
        try await Self.first(of: config.observeRepositories()) ?? []
    }

    /// The repository a selection belongs to.
    func repositoryID(for selection: ShareSelectionModel) async throws -> RepoID {
        switch selection {
        case .repository(let id):
            return id
        case .subset(let subset):
            return subset.repositoryID
        case .environment, .item:
            let preview = try await sharing.previewExport(selection)
            let fullName = preview.repositoryFullName.lowercased()
            guard let repository = try await repositories().first(where: { $0.fullName.lowercased() == fullName }) else {
                throw SharingError.repositoryNotFound
            }
            return repository.id
        case .folder:
            // A folder is shared whole, without a repository tree (v0.7.0).
            throw SharingError.repositoryNotFound
        }
    }

    /// The current value of an observation stream (database observations deliver it at once).
    private static func first<Value>(of stream: AsyncThrowingStream<Value, any Error>) async throws -> Value? {
        for try await value in stream {
            return value
        }
        return nil
    }
}
