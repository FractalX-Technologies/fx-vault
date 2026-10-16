import EnvTools
import Foundation
import VaultCore
import VaultStore

/// Builds an `fxvault.yml` that describes what a repository does now (v0.8.0, R9), for the user
/// to commit as a starting point. Names only.
///
/// - Stages: the destinations' stages, then the GitHub environments (production first when
///   present); `production` when there is none.
/// - Targets: `ci` for GitHub Actions; per provider one target whose identifier follows the stage
///   (`kv`, `api`, `web`, with `-2`… for a second vault or project); a destination without a stage
///   serves every stage.
/// - Vars: every name, a secret when any copy is a secret, public under a public prefix in Vercel,
///   sent to the targets that hold it, limited to the stages that have it when that is not all.
struct ManifestDraftBuilder {
    let config: ConfigStore
    let destinations: DestinationStore

    private static let githubTarget = "ci"
    private static let defaultStage = "production"

    private struct Place {
        let target: String
        /// nil: every stage.
        let stage: String?
        let provider: DestinationProvider?
    }

    func build(repositoryID: RepoID) throws -> ManifestModel {
        let environments = try config.fetchEnvironments(repositoryID: repositoryID).filter { !$0.isDeleted }
        let destinationModels = try destinations.fetchDestinations(repositoryID: repositoryID)
        let stages = Self.stages(destinations: destinationModels, environments: environments)
        var targets: [ManifestTargetModel] = []
        var placesByName: [String: (name: String, isSecret: Bool, isPublic: Bool, places: [Place])] = [:]

        func record(_ name: String, kind: ConfigKind, place: Place) {
            let key = GitHubNameValidator.foldKey(name)
            var entry = placesByName[key] ?? (name: name, isSecret: false, isPublic: false, places: [])
            entry.isSecret = entry.isSecret || kind == .secret
            if let provider = place.provider, PublicValuePolicy.publicPrefix(of: name, provider: provider) != nil {
                entry.isPublic = true
            }
            entry.places.append(place)
            placesByName[key] = entry
        }

        // GitHub Actions.
        let items = try config.fetchItems(repositoryID: repositoryID).filter { !$0.isDeleted }
        if !items.isEmpty {
            targets.append(ManifestTargetModel(name: Self.githubTarget, configuration: .githubActions(environment: nil)))
            let environmentNames = Dictionary(uniqueKeysWithValues: environments.map { ($0.id, $0.name) })
            for item in items {
                let stage = item.scope.environmentID.flatMap { environmentNames[$0] }
                record(item.name, kind: item.kind, place: Place(target: Self.githubTarget, stage: stage, provider: nil))
            }
        }

        // Destinations, one target per provider and identity series.
        var targetOfDestination: [DestinationID: String] = [:]
        for (provider, group) in Dictionary(grouping: destinationModels, by: \.provider).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            for (index, series) in Self.series(group).enumerated() {
                let name = Self.targetName(for: provider, index: index)
                guard let configuration = Self.configuration(provider: provider, series: series) else { continue }
                targets.append(ManifestTargetModel(name: name, configuration: configuration))
                for destination in series { targetOfDestination[destination.id] = name }
            }
        }
        for destination in destinationModels {
            guard let target = targetOfDestination[destination.id] else { continue }
            for item in try destinations.fetchItems(destinationID: destination.id) where !item.isDeleted {
                record(item.name, kind: item.kind, place: Place(target: target, stage: destination.stage, provider: destination.provider))
            }
        }

        let allStageKeys = Set(stages.map(EnvironmentNameValidator.foldKey))
        let vars = placesByName.values.sorted { $0.name < $1.name }.map { entry in
            let targetNames = entry.places.map(\.target).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let stageKeys = entry.places.contains { $0.stage == nil }
                ? allStageKeys
                : Set(entry.places.compactMap(\.stage).map(EnvironmentNameValidator.foldKey))
            let usedStages = stages.filter { stageKeys.contains(EnvironmentNameValidator.foldKey($0)) }
            let kind: ManifestVarKind = entry.isPublic ? .publicVariable : (entry.isSecret ? .secret : .variable)
            return ManifestVarModel(
                name: entry.name,
                kind: kind,
                targets: targetNames,
                stages: usedStages.count == stages.count || usedStages.isEmpty ? nil : usedStages
            )
        }
        return ManifestModel(version: ManifestModel.currentVersion, stages: stages, targets: targets, vars: vars)
    }

    private static func stages(destinations: [DestinationModel], environments: [EnvironmentModel]) -> [String] {
        var seen: Set<String> = []
        var stages: [String] = []
        for stage in destinations.compactMap(\.stage) + environments.map(\.name)
        where seen.insert(EnvironmentNameValidator.foldKey(stage)).inserted {
            stages.append(stage)
        }
        if let production = stages.firstIndex(where: { EnvironmentNameValidator.foldKey($0) == defaultStage }) {
            stages.insert(stages.remove(at: production), at: 0)
        }
        return stages.isEmpty ? [defaultStage] : stages
    }

    /// Splits one provider's destinations into series whose stages do not repeat (each series
    /// becomes one target with a per-stage identifier).
    private static func series(_ destinations: [DestinationModel]) -> [[DestinationModel]] {
        var series: [[DestinationModel]] = []
        for destination in destinations.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let key = destination.stageKey
            if let index = series.firstIndex(where: { group in
                key != nil && !group.contains { $0.stageKey == key || $0.stageKey == nil } && Self.sameProject(group[0], destination)
            }) {
                series[index].append(destination)
            } else {
                series.append([destination])
            }
        }
        return series
    }

    /// Vercel destinations share a target only within one project; vaults and Supabase projects
    /// change per stage by design.
    private static func sameProject(_ lhs: DestinationModel, _ rhs: DestinationModel) -> Bool {
        if case .vercel(let left, _, _, _) = lhs.target, case .vercel(let right, _, _, _) = rhs.target {
            return left == right
        }
        return true
    }

    private static func targetName(for provider: DestinationProvider, index: Int) -> String {
        let base = switch provider {
        case .azureKeyVault: "kv"
        case .supabase: "api"
        case .vercel: "web"
        }
        return index == 0 ? base : "\(base)-\(index + 1)"
    }

    private static func configuration(provider: DestinationProvider, series: [DestinationModel]) -> ManifestTargetConfiguration? {
        func value<Value: Sendable & Hashable>(_ pick: (DestinationModel) -> Value?) -> ManifestStageValue<Value>? {
            if series.count == 1, series[0].stage == nil, let only = pick(series[0]) {
                return .everyStage(only)
            }
            var perStage: [String: Value] = [:]
            for destination in series {
                guard let stage = destination.stage, let picked = pick(destination) else { continue }
                perStage[stage] = picked
            }
            return perStage.isEmpty ? nil : .perStage(perStage)
        }
        switch provider {
        case .azureKeyVault:
            return value { destination in
                if case .azureKeyVault(let name, _) = destination.target { return name }
                return nil
            }.map { .azureKeyVault(vault: $0) }
        case .supabase:
            return value { destination in
                if case .supabase(let ref) = destination.target { return ref }
                return nil
            }.map { .supabase(project: $0) }
        case .vercel:
            guard case .vercel(_, let projectName, let teamID, _) = series[0].target else { return nil }
            let environment: ManifestStageValue<ManifestVercelEnvironment>? = value { destination in
                if case .vercel(_, _, _, let environment) = destination.target {
                    return ManifestVercelEnvironment(rawValue: environment.rawValue)
                }
                return nil
            }
            return .vercel(project: projectName, team: teamID, environment: environment)
        }
    }
}
