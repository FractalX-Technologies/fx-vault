import EnvTools
import Foundation
import GitHubKit
import os
import VaultCore
import VaultCrypto
import VaultStore

/// The Overview of a repository's stages and its `fxvault.yml` (v0.8.0, tasks/todo.md R8, R9).
///
/// - ``stages(repositoryID:manifest:)``: the manifest's stages, then the destinations' stages,
///   then the GitHub environments, by fold key.
/// - ``overview(repositoryID:stage:manifest:)``: the matrix of one stage. Values are decrypted in
///   memory only to compare them (Differs) and to classify public names (Blocked), and wiped.
/// - ``manifest(repositoryID:)``: `fxvault.yml` from the default branch (names only), through the
///   repository's gh account.
public struct StageOverviewRepository: Sendable {
    public let session: VaultSession
    private let schedulers: (any GHSchedulerProviding)?

    public init(session: VaultSession, schedulers: (any GHSchedulerProviding)?) {
        self.session = session
        self.schedulers = schedulers
    }

    private var config: ConfigStore {
        ConfigStore(database: session.database)
    }

    private var destinations: DestinationStore {
        DestinationStore(database: session.database)
    }

    // MARK: - Stages

    /// The stages the Overview offers.
    public func stages(repositoryID: RepoID, manifest: ManifestModel?) throws(ConfigRepositoryError) -> [String] {
        try performConfig {
            var seen: Set<String> = []
            var stages: [String] = []
            func add(_ stage: String) {
                if seen.insert(EnvironmentNameValidator.foldKey(stage)).inserted { stages.append(stage) }
            }
            manifest?.stages.forEach(add)
            try destinations.fetchDestinations(repositoryID: repositoryID).compactMap(\.stage).forEach(add)
            try config.fetchEnvironments(repositoryID: repositoryID).filter { !$0.isDeleted }.map(\.name).forEach(add)
            return stages
        }
    }

    // MARK: - Overview

    /// The matrix of `stage`.
    ///
    /// - Throws: `.vault(.locked)` (comparisons need the keys), `.store`.
    public func overview(repositoryID: RepoID, stage: String, manifest: ManifestModel?) throws(ConfigRepositoryError) -> StageOverviewModel {
        try performConfig {
            let stageKey = EnvironmentNameValidator.foldKey(stage)
            let environment = try config.fetchEnvironments(repositoryID: repositoryID).first {
                !$0.isDeleted && $0.nameKey == stageKey
            }
            let repositoryItems = try config.fetchItems(repositoryID: repositoryID, scope: .repository)
            let environmentItems = try environment.map { try config.fetchItems(repositoryID: repositoryID, scope: .environment($0.id)) } ?? []
            let stageDestinations = try destinations.fetchDestinations(repositoryID: repositoryID).filter { $0.stageKey == stageKey }
            let destinationItems = try stageDestinations.map { ($0, try destinations.fetchItems(destinationID: $0.id)) }
            let comparison = try compare(
                github: Self.effectiveGitHubItems(repository: repositoryItems, environment: environmentItems),
                destinations: destinationItems
            )
            return StageOverviewBuilder.build(StageOverviewInput(
                stage: stage,
                environment: environment,
                repositoryItems: repositoryItems,
                environmentItems: environmentItems,
                destinations: destinationItems.map { (destination: $0.0, items: $0.1) },
                manifest: manifest,
                differing: comparison.differing,
                blocked: comparison.blocked
            ))
        }
    }

    /// The GitHub items a workflow of the stage sees: environment items win over repository
    /// items of the same name.
    private static func effectiveGitHubItems(repository: [ConfigItemModel], environment: [ConfigItemModel]) -> [ConfigItemModel] {
        let overridden = Set(environment.filter { !$0.isDeleted }.map(\.nameKey))
        return environment + repository.filter { !overridden.contains($0.nameKey) }
    }

    private struct Comparison {
        var differing: Set<ConfigItemID> = []
        var blocked: Set<ConfigItemID> = []
    }

    /// Decrypts the live values of every name in the stage to find the names whose values differ
    /// between columns, and the public names whose values look like secrets. Values are compared
    /// in constant time and wiped at once.
    private func compare(
        github: [ConfigItemModel],
        destinations: [(DestinationModel, [DestinationItemModel])]
    ) throws -> Comparison {
        try session.read { keys, tx in
            var comparison = Comparison()
            var byName: [String: [(ConfigItemID, SecretBytes)]] = [:]
            defer { byName.values.forEach { $0.forEach { $0.1.wipe() } } }
            for item in github where !item.isDeleted && item.hasValue {
                guard let source = try ItemCopySource.load(item.id, database: session.database, in: tx),
                      let value = try source.openValue(keys: keys)
                else { continue }
                byName[item.nameKey, default: []].append((item.id, value))
            }
            for (destination, items) in destinations {
                for item in items where !item.isDeleted && item.hasValue {
                    guard let record = try self.destinations.fetchItemRecord(id: item.id, in: tx),
                          let value = try DestinationFieldCipher.openValue(of: record, keys: keys)
                    else { continue }
                    if case .block = PublicValuePolicy.verdict(
                        name: item.name,
                        value: value,
                        provider: destination.provider,
                        isPublicAllowed: item.isPublicAllowed
                    ) {
                        comparison.blocked.insert(item.id)
                    }
                    byName[item.nameKey, default: []].append((item.id, value))
                }
            }
            for values in byName.values where values.count > 1 {
                let first = values[0].1
                if values.dropFirst().contains(where: { $0.1 != first }) {
                    comparison.differing.formUnion(values.map(\.0))
                }
            }
            return comparison
        }
    }

    // MARK: - fxvault.yml

    /// `fxvault.yml` from the repository's default branch, parsed. `.unavailable` when gh is not
    /// ready, the repository is not on GitHub yet, or the read failed (offline, no access).
    public func manifest(repositoryID: RepoID) async -> ManifestStateModel {
        guard let schedulers,
              let repository = try? RepoStore(database: session.database).fetch(id: repositoryID),
              repository.existsOnGitHub,
              let ref = try? GHRepoRef(owner: repository.ownerLogin, name: repository.name)
        else { return .unavailable }
        do throws(GHError) {
            let scheduler = try await schedulers.scheduler(for: repository.accountLogin)
            guard let file = try await scheduler.manifest(ref) else { return .none }
            return .read(sha: file.sha, result: ManifestParser.parse(file.text))
        } catch {
            Self.log.error("fxvault.yml read failed: \(error.logCode, privacy: .public)")
            return .unavailable
        }
    }

    /// A manifest describing what the repository does now (to commit as a starting point): the
    /// stages with destinations or GitHub items, a target per destination and for GitHub, and a
    /// var per name. Names only.
    public func draftManifest(repositoryID: RepoID) throws(ConfigRepositoryError) -> ManifestModel {
        try performConfig {
            try ManifestDraftBuilder(config: config, destinations: destinations).build(repositoryID: repositoryID)
        }
    }

    private static let log = Logger(subsystem: ConfigConstants.logSubsystem, category: "overview")
}
