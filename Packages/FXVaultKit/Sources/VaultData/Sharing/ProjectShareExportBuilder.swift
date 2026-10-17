import Foundation
import SharingKit
import VaultCore
import VaultCrypto
import VaultStore

/// Builds the project share bundle of a selection (v0.9.0, schema 4) from the vault rows.
///
/// - Values are decrypted inside `VaultSession.read` (rotation-safe) only when asked for.
/// - Deleted rows, environments pending deletion and empty repositories are left out.
/// - A value-missing secret travels by name only.
/// - Items linked to each other inside the file share a fresh `link` token (P9); a link group with
///   one selected member travels without one. The sender's `link_id`s never leave the vault.
/// - Destinations carry their target, stage and items, and the names marked public (R10); never
///   the connection that reaches them.
/// - Production places (``StageRisk``) are reported, so a passphrase can be refused (Q13).
struct ProjectShareExportBuilder: Sendable {
    let session: VaultSession
    let clock: any VaultClock

    /// The bundle of `selection` with what the share sheet and the sent log need. With
    /// `includeValues` the caller wipes the bundle (`ShareBundleModel.wipeValues()`).
    ///
    /// - Throws: `.repositoryNotFound`, `.environmentNotFound`, `.itemNotFound`,
    ///   `.config(.destinationNotFound)`, `.config(.folderNotFound)`, `.nothingToShare`,
    ///   `.share(.invalidPackage)`, `.vault(.locked)`.
    func build(
        _ selection: ShareBundleSelectionModel,
        senderName: String,
        appVersion: String,
        includeValues: Bool
    ) throws(SharingError) -> ProjectShareBuildModel {
        let database = session.database
        let createdAt = clock.now
        let built = try performSharing {
            try session.read { keys, tx in
                let keys = copy keys
                var rows = try ProjectShareRows.load(selection, database: database, tx: tx)
                rows.assignLinkTokens()
                return try rows.bundle(
                    createdAt: createdAt,
                    selection: selection,
                    senderName: senderName,
                    appVersion: appVersion,
                    open: includeValues ? { try $0.openValue(keys: keys) } : nil
                )
            }
        }
        guard built.bundle.itemCount > 0 || built.bundle.repositories.contains(where: Self.hasStructure) else {
            built.bundle.wipeValues()
            throw .nothingToShare
        }
        do {
            try ShareBundleValidator.validate(built.bundle, mode: includeValues ? .payload : .manifest)
        } catch {
            built.bundle.wipeValues()
            throw .share(error)
        }
        return built
    }

    /// An environment or a destination is worth sharing even without items (a branch policy, a
    /// target and stage).
    private static func hasStructure(_ entry: ShareBundleRepositoryModel) -> Bool {
        !entry.repository.environments.isEmpty || !entry.destinations.isEmpty
    }

    // MARK: - Stages

    /// The stages of `repositoryIDs`: every live environment name and every destination stage,
    /// deduplicated by fold key in repository order (P2).
    func stageOptions(repositoryIDs: [RepoID]) throws(SharingError) -> [ShareStageOptionModel] {
        let database = session.database
        return try performSharing {
            try database.read { tx in
                var options: [ShareStageOptionModel] = []
                var indexByKey: [String: Int] = [:]
                for repositoryID in repositoryIDs {
                    for stage in try Self.stages(of: repositoryID, database: database, tx: tx) {
                        let key = EnvironmentNameValidator.foldKey(stage)
                        if let index = indexByKey[key] {
                            if !options[index].repositoryIDs.contains(repositoryID) {
                                options[index].repositoryIDs.append(repositoryID)
                            }
                        } else {
                            indexByKey[key] = options.count
                            options.append(ShareStageOptionModel(
                                name: stage,
                                isProduction: StageRisk.isProduction(stage),
                                repositoryIDs: [repositoryID]
                            ))
                        }
                    }
                }
                return options
            }
        }
    }

    /// A selection of `repositoryIDs` expanded from `stages`: per repository the live environment
    /// named like each stage (fold key, as the Overview matches them) and the destinations of that
    /// stage, plus the repository level when asked for.
    func selection(
        repositoryIDs: [RepoID],
        stages: [String],
        includesRepositoryLevel: Bool,
        folderIDs: [FolderID],
        expiry: ShareExpiryChoice
    ) throws(SharingError) -> ShareBundleSelectionModel {
        let database = session.database
        let stageKeys = Set(stages.map(EnvironmentNameValidator.foldKey))
        let repositories = try performSharing {
            try database.read { tx in
                try repositoryIDs.map { repositoryID in
                    guard try RepoStore(database: database).fetch(id: repositoryID, in: tx) != nil else {
                        throw SharingError.repositoryNotFound
                    }
                    let environments = try ConfigStore(database: database).fetchEnvironments(repositoryID: repositoryID, in: tx)
                        .filter { !$0.isDeleted && stageKeys.contains($0.nameKey) }
                    let destinations = try DestinationStore(database: database).fetchDestinationRecords(repositoryID: repositoryID, in: tx)
                        .filter { $0.stageKey.map(stageKeys.contains) ?? false }
                    return ShareBundleRepositorySelectionModel(
                        repositoryID: repositoryID,
                        includesRepositoryLevel: includesRepositoryLevel,
                        environmentIDs: Set(environments.map(\.id)),
                        destinationIDs: Set(destinations.map(\.id))
                    )
                }
            }
        }
        return ShareBundleSelectionModel(repositories: repositories, folderIDs: folderIDs, stages: stages, expiry: expiry)
    }

    private static func stages(of repositoryID: RepoID, database: VaultDatabase, tx: StoreTransaction) throws -> [String] {
        let environments = try ConfigStore(database: database).fetchEnvironments(repositoryID: repositoryID, in: tx)
            .filter { !$0.isDeleted }
            .map(\.name)
        let destinations = try DestinationStore(database: database).fetchDestinationRecords(repositoryID: repositoryID, in: tx)
            .compactMap(\.stage)
        return environments + destinations
    }

    // MARK: - Preview

    /// The names and counts of a built bundle (no values).
    static func preview(_ built: ProjectShareBuildModel) -> ShareBundleExportPreviewModel {
        ShareBundleExportPreviewModel(
            summary: built.bundle.contentSummary,
            stages: built.bundle.stages,
            valueMissingNames: built.valueMissingNames,
            productionPlaces: built.productionPlaces,
            expiresAt: built.bundle.expiresAt
        )
    }
}

/// A built bundle with what the share sheet and the sent log need besides it.
struct ProjectShareBuildModel: Sendable {
    let bundle: ShareBundleModel
    /// Production environments and destinations in the bundle, by label.
    let productionPlaces: [String]
    /// Secrets travelling by name only, by label.
    let valueMissingNames: [String]
    /// Names only, for `sent_shares`.
    let sentSummary: SentShareSummaryModel
}

/// How destinations are named outside the app's own copy: the sent log and summaries.
enum ShareDestinationLabel {
    static func text(_ target: DestinationTargetModel) -> String {
        switch target {
        case .azureKeyVault(let vaultName, _): "Azure Key Vault \(vaultName)"
        case .supabase(let projectRef): "Supabase \(projectRef)"
        case .vercel(_, let projectName, _, let environment): "Vercel \(projectName) (\(environment.rawValue))"
        }
    }

    /// A destination is a production place when its stage is, or, without a stage, when it is a
    /// Vercel production environment.
    static func isProduction(_ target: DestinationTargetModel, stage: String?) -> Bool {
        if let stage { return StageRisk.isProduction(stage) }
        if case .vercel(_, _, _, .production) = target { return true }
        return false
    }
}

// MARK: - Rows

/// One selected row of any of the three item tables, with what the bundle needs from it.
private enum ProjectShareRow {
    case config(ConfigItemRecord)
    case destination(DestinationItemRecord)
    case folder(FolderItemRecord)

    var kind: ConfigKind {
        switch self {
        case .config(let record): record.kind
        case .destination(let record): record.kind
        case .folder(let record): record.kind
        }
    }

    var name: String {
        switch self {
        case .config(let record): record.name
        case .destination(let record): record.name
        case .folder(let record): record.name
        }
    }

    var linkID: ItemLinkID? {
        switch self {
        case .config(let record): record.linkID
        case .destination(let record): record.linkID
        case .folder(let record): record.linkID
        }
    }

    var hasValue: Bool {
        switch self {
        case .config(let record): record.valueCiphertext != nil
        case .destination(let record): record.valueCiphertext != nil
        case .folder: true
        }
    }

    func openValue(keys: borrowing UnlockedKeys) throws -> SecretBytes? {
        switch self {
        case .config(let record): try ConfigFieldCipher.openValue(of: record, keys: keys)
        case .destination(let record): try DestinationFieldCipher.openValue(of: record, keys: keys)
        case .folder(let record): try FolderFieldCipher.openValue(of: record, keys: keys)
        }
    }

    /// `synced` only when the remote has exactly the local value: nothing pending and a verified
    /// write. A folder row is never synced anywhere.
    var syncState: ShareSyncState {
        switch self {
        case .config(let record):
            ShareExportBuilder.syncState(record)
        case .destination(let record):
            record.syncStatus == .synced && record.verifyState == .verified ? .synced : .pending
        case .folder:
            .pending
        }
    }

    var githubUpdatedAt: Date? {
        if case .config(let record) = self { return record.remoteUpdatedAt }
        return nil
    }
}

/// An environment in the selection: whole (its policy travels) or partial.
private struct ProjectShareEnvironment {
    let environment: EnvironmentModel
    let isWhole: Bool
    let rows: [ProjectShareRow]
}

/// A destination in the selection with its selected rows.
private struct ProjectShareDestination {
    let record: DestinationRecord
    let target: DestinationTargetModel
    let rows: [ProjectShareRow]
}

/// One repository of the selection, loaded.
private struct ProjectShareRepository {
    let repository: RepoModel
    let repositoryRows: [ProjectShareRow]
    let environments: [ProjectShareEnvironment]
    let destinations: [ProjectShareDestination]

    var isEmpty: Bool {
        repositoryRows.isEmpty && environments.isEmpty && destinations.isEmpty
    }
}

/// One folder of the selection, loaded.
private struct ProjectShareFolder {
    let record: FolderRecord
    let rows: [ProjectShareRow]
}

/// Every row a bundle selection covers (live rows only), then the bundle.
private struct ProjectShareRows {
    var repositories: [ProjectShareRepository]
    var folders: [ProjectShareFolder]
    /// The `link` token of every link group with at least two selected members.
    var tokens: [ItemLinkID: String] = [:]

    static func load(_ selection: ShareBundleSelectionModel, database: VaultDatabase, tx: StoreTransaction) throws -> ProjectShareRows {
        var merged: [ShareBundleRepositorySelectionModel] = []
        for part in selection.repositories {
            if let index = merged.firstIndex(where: { $0.repositoryID == part.repositoryID }) {
                merged[index].includesRepositoryLevel = merged[index].includesRepositoryLevel || part.includesRepositoryLevel
                merged[index].environmentIDs.formUnion(part.environmentIDs)
                merged[index].itemIDs.formUnion(part.itemIDs)
                merged[index].destinationIDs.formUnion(part.destinationIDs)
                merged[index].destinationItemIDs.formUnion(part.destinationItemIDs)
            } else {
                merged.append(part)
            }
        }
        let repositories = try merged.map { try loadRepository($0, database: database, tx: tx) }.filter { !$0.isEmpty }
        var seenFolders = Set<FolderID>()
        let folders = try selection.folderIDs.filter { seenFolders.insert($0).inserted }.map { folderID in
            let store = FolderStore(database: database)
            guard let record = try store.fetchFolder(id: folderID, in: tx) else { throw SharingError.config(.folderNotFound) }
            return ProjectShareFolder(record: record, rows: try store.fetchItemRecords(folderID: folderID, in: tx).map(ProjectShareRow.folder))
        }
        return ProjectShareRows(repositories: repositories, folders: folders.filter { !$0.rows.isEmpty })
    }

    private static func loadRepository(
        _ part: ShareBundleRepositorySelectionModel,
        database: VaultDatabase,
        tx: StoreTransaction
    ) throws -> ProjectShareRepository {
        let config = ConfigStore(database: database)
        guard let repository = try RepoStore(database: database).fetch(id: part.repositoryID, in: tx) else {
            throw SharingError.repositoryNotFound
        }
        let live = try config.fetchEnvironments(repositoryID: repository.id, in: tx).filter { !$0.isDeleted }
        let liveIDs = Set(live.map(\.id))
        guard part.environmentIDs.isSubset(of: liveIDs) else { throw SharingError.environmentNotFound }
        let records = try config.fetchItemRecords(repositoryID: repository.id, in: tx).filter { !$0.isDeleted }
        let recordsByID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var chosen = Set<ConfigItemID>()
        for itemID in part.itemIDs {
            guard let record = recordsByID[itemID] else { throw SharingError.itemNotFound }
            if let environmentID = record.environmentID, !liveIDs.contains(environmentID) {
                throw SharingError.environmentNotFound
            }
            chosen.insert(itemID)
        }
        let repositoryRows = records.filter { record in
            record.environmentID == nil && (part.includesRepositoryLevel || chosen.contains(record.id))
        }
        let environments = live.compactMap { environment -> ProjectShareEnvironment? in
            let isWhole = part.environmentIDs.contains(environment.id)
            let rows = records.filter { record in
                record.environmentID == environment.id && (isWhole || chosen.contains(record.id))
            }
            guard isWhole || !rows.isEmpty else { return nil }
            return ProjectShareEnvironment(environment: environment, isWhole: isWhole, rows: rows.map(ProjectShareRow.config))
        }
        let destinations = try loadDestinations(part, repositoryID: repository.id, database: database, tx: tx)
        return ProjectShareRepository(
            repository: repository,
            repositoryRows: repositoryRows.map(ProjectShareRow.config),
            environments: environments,
            destinations: destinations
        )
    }

    private static func loadDestinations(
        _ part: ShareBundleRepositorySelectionModel,
        repositoryID: RepoID,
        database: VaultDatabase,
        tx: StoreTransaction
    ) throws -> [ProjectShareDestination] {
        let store = DestinationStore(database: database)
        let records = try store.fetchDestinationRecords(repositoryID: repositoryID, in: tx)
        let recordIDs = Set(records.map(\.id))
        guard part.destinationIDs.isSubset(of: recordIDs) else { throw SharingError.config(.destinationNotFound) }
        var chosenByDestination: [DestinationID: Set<ConfigItemID>] = [:]
        for itemID in part.destinationItemIDs {
            guard let item = try store.fetchItemRecord(id: itemID, in: tx), !item.isDeleted, recordIDs.contains(item.destinationID) else {
                throw SharingError.itemNotFound
            }
            chosenByDestination[item.destinationID, default: []].insert(itemID)
        }
        return try records.compactMap { record -> ProjectShareDestination? in
            let isWhole = part.destinationIDs.contains(record.id)
            let chosen = chosenByDestination[record.id] ?? []
            guard isWhole || !chosen.isEmpty else { return nil }
            let rows = try store.fetchItemRecords(destinationID: record.id, in: tx)
                .filter { !$0.isDeleted && (isWhole || chosen.contains($0.id)) }
            return ProjectShareDestination(record: record, target: try record.target(), rows: rows.map(ProjectShareRow.destination))
        }
    }

    // MARK: Links

    /// A fresh lowercase UUID token for every link group with at least two selected rows.
    mutating func assignLinkTokens() {
        var counts: [ItemLinkID: Int] = [:]
        for row in allRows {
            if let linkID = row.linkID { counts[linkID, default: 0] += 1 }
        }
        tokens = Dictionary(
            uniqueKeysWithValues: counts.filter { $0.value >= 2 }.keys.map { ($0, UUID().uuidString.lowercased()) }
        )
    }

    private var allRows: [ProjectShareRow] {
        repositories.flatMap { entry in
            entry.repositoryRows + entry.environments.flatMap(\.rows) + entry.destinations.flatMap(\.rows)
        } + folders.flatMap(\.rows)
    }

    // MARK: Bundle

    /// The bundle, the production places, the value-missing names and the sent-log summary.
    /// `open` decrypts a row's value (nil: a manifest without values).
    func bundle(
        createdAt: Date,
        selection: ShareBundleSelectionModel,
        senderName: String,
        appVersion: String,
        open: ((ProjectShareRow) throws -> SecretBytes?)?
    ) throws -> ProjectShareBuildModel {
        var opened: [SecretBytes] = []
        do {
            func item(_ row: ProjectShareRow) throws -> ShareItemModel {
                let value = try open?(row)
                if let value { opened.append(value) }
                return ShareItemModel(
                    name: row.name,
                    value: value,
                    valueState: row.hasValue ? .present : .missing,
                    githubUpdatedAt: row.githubUpdatedAt,
                    syncState: row.syncState,
                    linkToken: row.linkID.flatMap { tokens[$0] }
                )
            }
            func items(_ rows: [ProjectShareRow], kind: ConfigKind) throws -> [ShareItemModel] {
                try rows.filter { $0.kind == kind }.map(item)
            }
            var productionPlaces: [String] = []
            var valueMissing: [String] = []
            var places: [SentSharePlaceModel] = []
            func note(_ rows: [ProjectShareRow], place: String, kind: SentSharePlaceModel.Kind, repository: String?, name: String?) {
                valueMissing += rows.filter { $0.kind == .secret && !$0.hasValue }.map { "\(place) · \($0.name)" }
                places.append(SentSharePlaceModel(
                    kind: kind,
                    repository: repository,
                    name: name,
                    secretNames: rows.filter { $0.kind == .secret }.map(\.name),
                    variableNames: rows.filter { $0.kind == .variable }.map(\.name)
                ))
            }
            var repositories: [ShareBundleRepositoryModel] = []
            for entry in self.repositories {
                let fullName = "\(entry.repository.ownerLogin)/\(entry.repository.name)"
                if !entry.repositoryRows.isEmpty {
                    note(entry.repositoryRows, place: fullName, kind: .repository, repository: fullName, name: nil)
                }
                let environments = try entry.environments.map { selected in
                    let environment = selected.environment
                    if StageRisk.isProduction(environment.name) {
                        productionPlaces.append("\(fullName) · \(environment.name)")
                    }
                    note(selected.rows, place: "\(fullName) · \(environment.name)", kind: .environment, repository: fullName, name: environment.name)
                    return ShareEnvironmentModel(
                        name: environment.name,
                        deploymentBranchPolicy: selected.isWhole ? ShareBranchPolicyModel(environment.branchPolicy) : nil,
                        secrets: try items(selected.rows, kind: .secret),
                        variables: try items(selected.rows, kind: .variable)
                    )
                }
                let destinations = try entry.destinations.map { selected in
                    let label = ShareDestinationLabel.text(selected.target)
                    if ShareDestinationLabel.isProduction(selected.target, stage: selected.record.stage) {
                        productionPlaces.append("\(fullName) · \(label)")
                    }
                    note(selected.rows, place: "\(fullName) · \(label)", kind: .destination, repository: fullName, name: label)
                    let publicNames = selected.rows.compactMap { row -> String? in
                        guard case .destination(let record) = row, record.isPublicAllowed else { return nil }
                        return record.name
                    }
                    return ShareDestinationModel(
                        target: selected.target,
                        stage: selected.record.stage,
                        secrets: try items(selected.rows, kind: .secret),
                        variables: try items(selected.rows, kind: .variable),
                        publicNames: publicNames
                    )
                }
                repositories.append(ShareBundleRepositoryModel(
                    repository: ShareRepositoryModel(
                        owner: entry.repository.ownerLogin,
                        name: entry.repository.name,
                        githubRepoID: entry.repository.githubID,
                        secrets: try items(entry.repositoryRows, kind: .secret),
                        variables: try items(entry.repositoryRows, kind: .variable),
                        environments: environments
                    ),
                    destinations: destinations
                ))
            }
            let folders = try self.folders.map { folder in
                note(folder.rows, place: folder.record.name, kind: .folder, repository: nil, name: folder.record.name)
                return ShareBundleFolderModel(
                    name: folder.record.name,
                    secrets: try items(folder.rows, kind: .secret),
                    variables: try items(folder.rows, kind: .variable)
                )
            }
            let stages = Self.uniqueStages(selection.stages)
            let bundle = ShareBundleModel(
                createdAt: createdAt,
                expiry: selection.expiry,
                producer: ShareProducerModel(version: appVersion),
                sender: ShareSenderModel(displayName: DisplayNameSanitizer.sanitize(senderName)),
                stages: stages,
                repositories: repositories,
                folders: folders
            )
            return ProjectShareBuildModel(
                bundle: bundle,
                productionPlaces: productionPlaces,
                valueMissingNames: valueMissing,
                sentSummary: SentShareSummaryModel(stages: stages, places: places)
            )
        } catch {
            opened.forEach { $0.wipe() }
            throw error
        }
    }

    /// The chosen stages without blanks or fold-key duplicates, in order.
    private static func uniqueStages(_ stages: [String]) -> [String] {
        var seen = Set<String>()
        return stages.filter { stage in
            !stage.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert(EnvironmentNameValidator.foldKey(stage)).inserted
        }
    }
}
