import EnvTools
import Foundation
import VaultCore

/// What the Overview of one stage is built from (no values: comparisons arrive as id sets).
struct StageOverviewInput {
    let stage: String
    /// The environment named like the stage, or nil.
    let environment: EnvironmentModel?
    let repositoryItems: [ConfigItemModel]
    let environmentItems: [ConfigItemModel]
    let destinations: [(destination: DestinationModel, items: [DestinationItemModel])]
    let manifest: ManifestModel?
    /// Items whose value differs from another value under the same name in this stage.
    let differing: Set<ConfigItemID>
    /// Public names whose value looks like a secret (``PublicValuePolicy``).
    let blocked: Set<ConfigItemID>
}

/// Builds the Overview of one stage (v0.8.0, tasks/todo.md R8, R9). Pure.
///
/// Columns: GitHub (repository level, where an environment item of the same name wins, as in a
/// workflow), then each destination of the stage. Rows: every name in them plus the manifest's
/// vars for the stage, runtime first, then public, build and unknown, each by name. With a
/// manifest, a column a manifest target maps to shows Missing for a var sent there that it lacks,
/// and Extra for an item it has that no var sends there.
enum StageOverviewBuilder {
    fileprivate struct Entry {
        let id: ConfigItemID
        let kind: ConfigKind
        let status: ConfigSyncStatus
        let isDeleted: Bool
        let linkCount: Int
        /// Held by a share file (v0.9.0).
        let isHeld: Bool
    }

    static func build(_ input: StageOverviewInput) -> StageOverviewModel {
        let columns: [StageOverviewColumnModel] = [.github(environment: input.environment)]
            + input.destinations.map { .destination($0.destination) }
        var entries: [[String: Entry]] = [githubEntries(input)]
        for (_, items) in input.destinations {
            entries.append(Dictionary(items.map { (key($0.name), Entry($0)) }, uniquingKeysWith: { first, _ in first }))
        }
        let plan = ManifestPlan(input: input, columns: columns)
        var names: [String: String] = [:]
        for item in input.repositoryItems + input.environmentItems { names[key(item.name)] = item.name }
        for (_, items) in input.destinations { for item in items { names[key(item.name)] = item.name } }
        for variable in plan.vars { names[key(variable.name)] = names[key(variable.name)] ?? variable.name }

        var rows: [StageOverviewRowModel] = []
        var findings: [StageOverviewFindingModel] = plan.missingDestinations
        for (rowKey, name) in names {
            var cells: [StageOverviewCellModel] = []
            var itemIDs: [ConfigItemID?] = []
            var linkCount = 0
            let variable = plan.vars.first { key($0.name) == rowKey }
            for (index, column) in entries.enumerated() {
                let columnID = columns[index].id
                guard let entry = column[rowKey] else {
                    let isExpected = plan.expected[index]?.contains(rowKey) == true
                    cells.append(isExpected ? .missing : .notUsed)
                    itemIDs.append(nil)
                    if isExpected { findings.append(.missing(name: name, column: columnID)) }
                    continue
                }
                linkCount = max(linkCount, entry.linkCount)
                itemIDs.append(entry.id)
                let cell = cell(for: entry, input: input, plan: plan, column: index, rowKey: rowKey)
                cells.append(cell)
                switch cell {
                case .extra: findings.append(.extra(name: name, column: columnID))
                case .blocked: findings.append(.blocked(name: name, column: columnID))
                default: break
                }
                if variable?.isSecret == true, entry.kind == .variable, !entry.isDeleted {
                    findings.append(.kindMismatch(name: name, column: columnID))
                }
            }
            rows.append(StageOverviewRowModel(
                name: name,
                cycle: cycle(of: name, variable: variable, plan: plan, cells: cells, columns: columns),
                linkCount: linkCount,
                cells: cells,
                itemIDs: itemIDs
            ))
        }
        rows.sort { ($0.cycle, $0.name) < ($1.cycle, $1.name) }
        return StageOverviewModel(
            stage: input.stage,
            columns: columns,
            rows: rows,
            findings: findings.sorted { $0.id < $1.id },
            usesManifest: plan.isActive
        )
    }

    // MARK: - Cells

    private static func cell(for entry: Entry, input: StageOverviewInput, plan: ManifestPlan, column: Int, rowKey: String) -> StageOverviewCellModel {
        if entry.isDeleted || entry.status == .deleted {
            return .willDelete
        }
        if input.blocked.contains(entry.id) {
            return .blocked
        }
        if plan.covered.contains(column), plan.expected[column]?.contains(rowKey) != true {
            return .extra
        }
        switch entry.status {
        case .blocked:
            return .valueMissing
        case .added, .modified, .willPush:
            return entry.isHeld ? .held : .willPush
        case .synced, .unverifiedShare:
            return input.differing.contains(entry.id) ? .differs : .synced
        case .deleted:
            return .willDelete
        }
    }

    private static func cycle(
        of name: String,
        variable: ManifestVarModel?,
        plan: ManifestPlan,
        cells: [StageOverviewCellModel],
        columns: [StageOverviewColumnModel]
    ) -> StageOverviewCycle {
        if let variable {
            if variable.isPublic { return .publicValue }
            let targetColumns = variable.targets.compactMap { plan.columnOfTarget[$0] }
            let providers = variable.targets.compactMap { plan.manifest?.target(named: $0)?.provider }
            if !providers.isEmpty, providers.allSatisfy({ $0 == .githubActions }) { return .build }
            if !targetColumns.isEmpty, targetColumns.allSatisfy({ $0 == 0 }) { return .build }
            return .runtime
        }
        let used = cells.indices.filter { cells[$0] != .notUsed && cells[$0] != .missing }
        guard !used.isEmpty else { return .unknown }
        if used == [0] { return .build }
        for index in used where index > 0 {
            if case .destination(let destination) = columns[index],
               PublicValuePolicy.publicPrefix(of: name, provider: destination.provider) != nil {
                return .publicValue
            }
        }
        return used.contains(where: { $0 > 0 }) ? .runtime : .unknown
    }

    // MARK: - GitHub

    private static func githubEntries(_ input: StageOverviewInput) -> [String: Entry] {
        var entries: [String: Entry] = [:]
        for item in input.repositoryItems {
            entries[key(item.name)] = Entry(item)
        }
        for item in input.environmentItems {
            entries[key(item.name)] = Entry(item)
        }
        return entries
    }

    private static func key(_ name: String) -> String {
        GitHubNameValidator.foldKey(name)
    }

    // MARK: - The manifest's view of this stage

    /// Which column each manifest target maps to at the stage, and the names each column should
    /// hold.
    private struct ManifestPlan {
        let manifest: ManifestModel?
        let vars: [ManifestVarModel]
        let columnOfTarget: [String: Int]
        let expected: [Int: Set<String>]
        let covered: Set<Int>
        let missingDestinations: [StageOverviewFindingModel]

        var isActive: Bool {
            manifest != nil && !columnOfTarget.isEmpty
        }

        init(input: StageOverviewInput, columns: [StageOverviewColumnModel]) {
            guard let manifest = input.manifest, let stage = manifest.stage(matching: input.stage) else {
                self.manifest = input.manifest
                vars = []
                columnOfTarget = [:]
                expected = [:]
                covered = []
                missingDestinations = []
                return
            }
            self.manifest = manifest
            var columnOfTarget: [String: Int] = [:]
            var missing: [StageOverviewFindingModel] = []
            for target in manifest.targets {
                guard let location = target.location(for: stage) else { continue }
                if let index = Self.column(for: location, in: columns) {
                    columnOfTarget[target.name] = index
                } else {
                    missing.append(.destinationNotAdded(target: target.name, location: location))
                }
            }
            let vars = manifest.vars(for: stage)
            var expected: [Int: Set<String>] = [:]
            for variable in vars {
                for target in variable.targets {
                    guard let index = columnOfTarget[target] else { continue }
                    expected[index, default: []].insert(GitHubNameValidator.foldKey(variable.name))
                }
            }
            self.vars = vars
            self.columnOfTarget = columnOfTarget
            self.expected = expected
            covered = Set(columnOfTarget.values)
            missingDestinations = missing
        }

        static func column(for location: ManifestLocation, in columns: [StageOverviewColumnModel]) -> Int? {
            columns.firstIndex { column in
                switch (location, column) {
                case (.githubEnvironment, .github):
                    return true
                case (.keyVault(let vaultName), .destination(let destination)):
                    if case .azureKeyVault(let name, _) = destination.target { return name.lowercased() == vaultName.lowercased() }
                    return false
                case (.supabase(let projectRef), .destination(let destination)):
                    if case .supabase(let ref) = destination.target { return ref == projectRef }
                    return false
                case (.vercel(let project, _, let environment), .destination(let destination)):
                    if case .vercel(let projectID, let projectName, _, let target) = destination.target {
                        return (projectID == project || projectName == project) && target.rawValue == environment.rawValue
                    }
                    return false
                default:
                    return false
                }
            }
        }
    }
}

private extension StageOverviewBuilder.Entry {
    init(_ item: ConfigItemModel) {
        self.init(
            id: item.id,
            kind: item.kind,
            status: item.syncStatus,
            isDeleted: item.isDeleted,
            linkCount: item.isLinked ? item.linkCount : 0,
            isHeld: item.isHeld
        )
    }

    init(_ item: DestinationItemModel) {
        self.init(
            id: item.id,
            kind: item.kind,
            status: item.syncStatus,
            isDeleted: item.isDeleted,
            linkCount: item.isLinked ? item.linkCount : 0,
            isHeld: item.isHeld
        )
    }
}
