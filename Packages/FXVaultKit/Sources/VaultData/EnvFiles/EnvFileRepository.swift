import Darwin
import EnvTools
import Foundation
import os
import SyncEngine
import VaultCore
import VaultCrypto
import VaultStore

/// `.env` import and export (§5.13, §7.8; M5 `EnvImportScreen`, `EnvExportScreen`).
///
/// **Import**: ``readFile(at:)`` / ``parse(_:)`` run `DotEnvParser` and `EnvImportPlanner`
/// (key fixes, credential pre-marking, D32 normalization); ``conflicts(for:in:repositoryID:scope:)``
/// finds existing items; ``applyImport(_:selections:repositoryID:scope:)`` writes the chosen rows
/// into one scope in one transaction (new rows, revived tombstones, or overwritten values).
///
/// **Export**: ``exportPreview(repositoryID:scope:)`` lists what will be written;
/// ``inspectDestination(_:)`` reports iCloud sync and git exposure (hardened git, D4–D6);
/// ``export(repositoryID:scope:to:authorization:existingFile:headerComments:)`` needs a fresh
/// ``EnvExportAuthorizationModel`` from `ReauthGate`, serializes with `DotEnvSerializer` and
/// writes a 0600 file with `SecureFileWriter`; ``addGitignoreEntry(relativePath:repositoryRoot:)``
/// applies the offered `.gitignore` line. Value-missing secrets are never exported (§7.8).
///
/// Folders (v0.7.0): the `place:` overloads import into and export from a folder as well as a
/// repository scope; a folder import is final (a folder never syncs).
public struct EnvFileRepository: Sendable {
    public let session: VaultSession
    private let config: ConfigRepository
    private let folders: FolderRepository
    private let destinations: DestinationRepository
    private let gitignoreChecker: any GitignoreChecker
    private let cloudSyncDetector: CloudSyncDetector
    private let fileWriter: SecureFileWriter

    /// Mode given to a `.gitignore` FX Vault creates (an existing file keeps its own mode).
    static let gitignoreFileMode: mode_t = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
    private static let log = Logger(subsystem: ConfigConstants.logSubsystem, category: "env-files")

    /// - Parameters:
    ///   - gitignoreChecker: `GitServiceGitignoreChecker` in the app, a fake in tests.
    ///   - writePolicy: the WRITE-collaborator policy imports obey (§2).
    public init(
        session: VaultSession,
        gitignoreChecker: any GitignoreChecker,
        cloudSyncDetector: CloudSyncDetector = CloudSyncDetector(),
        fileWriter: SecureFileWriter = SecureFileWriter(),
        clock: any VaultClock = SystemClock(),
        writePolicy: WriteCollaboratorPolicy = .default
    ) {
        self.session = session
        config = ConfigRepository(session: session, clock: clock, writePolicy: writePolicy)
        folders = FolderRepository(session: session, clock: clock)
        destinations = DestinationRepository(session: session, clock: clock)
        self.gitignoreChecker = gitignoreChecker
        self.cloudSyncDetector = cloudSyncDetector
        self.fileWriter = fileWriter
    }

    // MARK: - Import

    /// Reads (``SecretFileReader``) and plans a `.env` file. The file's bytes are wiped after
    /// parsing. Throws `.parse(.fileTooLarge)` above `EnvToolsLimits.maxEnvFileBytes`, otherwise
    /// `.fileUnreadable` (also for a folder, a pipe or a file that changes while it is read).
    public func readFile(at url: URL) throws(EnvFileError) -> EnvImportPreviewModel {
        let contents: SecretBytes
        do {
            contents = try SecretFileReader.read(url, maxBytes: EnvToolsLimits.maxEnvFileBytes)
        } catch .tooLarge {
            throw .parse(.fileTooLarge(limit: EnvToolsLimits.maxEnvFileBytes))
        } catch {
            throw .fileUnreadable
        }
        defer { contents.wipe() }
        return try parse(contents)
    }

    /// Plans pasted or loaded `.env` text. The caller wipes `contents`; the preview owns copies
    /// it wipes with ``EnvImportPreviewModel/wipe()``.
    public func parse(_ contents: SecretBytes) throws(EnvFileError) -> EnvImportPreviewModel {
        let result: DotEnvParseResult
        do {
            result = try DotEnvParser.parse(contents)
        } catch {
            throw .parse(error)
        }
        defer { result.entries.forEach { $0.value.wipe() } }
        return EnvImportPreviewModel(candidates: EnvImportPlanner.plan(result), issues: result.issues)
    }

    /// The live items `selections` would collide with in `scope`, by candidate index (the
    /// table's Conflict column).
    public func conflicts(
        for selections: [EnvImportSelectionModel],
        in preview: EnvImportPreviewModel,
        repositoryID: RepoID,
        scope: ConfigScope
    ) throws(EnvFileError) -> [Int: ConfigItemModel] {
        let items: [ConfigItemModel]
        do {
            items = try ConfigStore(database: session.database).fetchItems(repositoryID: repositoryID, scope: scope)
        } catch {
            throw .config(.wrap(error))
        }
        var result: [Int: ConfigItemModel] = [:]
        for selection in selections {
            let key = GitHubNameValidator.foldKey(selection.name)
            if let item = items.first(where: { !$0.isDeleted && $0.kind == selection.kind && $0.nameKey == key }) {
                result[selection.candidateIndex] = item
            }
        }
        return result
    }

    /// The candidates of `selections` that would collide with a live item of `place` (same name
    /// and kind): the table's Conflict column (v0.7.0).
    public func conflictingCandidates(
        for selections: [EnvImportSelectionModel],
        in preview: EnvImportPreviewModel,
        place: ItemPlaceModel
    ) throws(EnvFileError) -> Set<Int> {
        switch place {
        case .scope(let repositoryID, let scope):
            return Set(try conflicts(for: selections, in: preview, repositoryID: repositoryID, scope: scope).keys)
        case .folder(let folderID):
            let items: [FolderItemModel]
            do {
                items = try folders.items(folderID: folderID)
            } catch {
                throw .config(error)
            }
            let taken = Set(items.map { ConfigRepository.TargetKey(kind: $0.kind, name: $0.nameKey) })
            return Set(selections.filter {
                taken.contains(ConfigRepository.TargetKey(kind: $0.kind, name: GitHubNameValidator.foldKey($0.name)))
            }.map(\.candidateIndex))
        case .destination(let destinationID):
            // A destination holds one item per name, whatever its kind.
            let items: [DestinationItemModel]
            do {
                items = try destinations.items(destinationID: destinationID)
            } catch {
                throw .config(error)
            }
            let taken = Set(items.filter { !$0.isDeleted }.map(\.nameKey))
            return Set(selections.filter { taken.contains(GitHubNameValidator.foldKey($0.name)) }.map(\.candidateIndex))
        }
    }

    /// Imports the selected candidates into `place` in one transaction: a repository scope
    /// (``applyImport(_:selections:repositoryID:scope:)``) or a folder (v0.7.0), where existing
    /// names are skipped or overwritten the same way and the import is final.
    @discardableResult
    public func applyImport(
        _ preview: EnvImportPreviewModel,
        selections: [EnvImportSelectionModel],
        place: ItemPlaceModel
    ) throws(EnvFileError) -> EnvImportResultModel {
        switch place {
        case .scope(let repositoryID, let scope):
            return try applyImport(preview, selections: selections, repositoryID: repositoryID, scope: scope)
        case .folder(let folderID):
            return try applyFolderImport(preview, selections: selections, folderID: folderID)
        case .destination(let destinationID):
            return try applyDestinationImport(preview, selections: selections, destinationID: destinationID)
        }
    }

    /// Imports the selected candidates into `scope` in one transaction (§7.1 rules apply: a
    /// deleted name is revived, an existing one is skipped or overwritten). Invalid names,
    /// unusable values and duplicates within the import are skipped and reported.
    ///
    /// - Throws: `.config` (`.readOnly`, `.environmentDeleted`, `.validation(.scopeFull)`,
    ///   `.vault(.locked)`, ...); nothing is written then.
    @discardableResult
    public func applyImport(
        _ preview: EnvImportPreviewModel,
        selections: [EnvImportSelectionModel],
        repositoryID: RepoID,
        scope: ConfigScope
    ) throws(EnvFileError) -> EnvImportResultModel {
        var added: [String] = []
        var overwritten: [String] = []
        var skipped: [EnvImportSkipModel] = []
        var stripped: [String] = []
        do throws(ConfigRepositoryError) {
            try config.batch(repositoryID: repositoryID) { batch in
                try batch.requireEditable(scope)
                var seen: Set<String> = []
                for selection in selections {
                    let name: String
                    let candidate: EnvImportCandidateModel
                    switch Self.resolve(selection, in: preview, seen: &seen) {
                    case .accepted(let validName, let accepted):
                        (name, candidate) = (validName, accepted)
                    case .skipped(let skip):
                        skipped.append(skip)
                        continue
                    }
                    if let existing = batch.liveRow(scope: scope, kind: selection.kind, name: name) {
                        guard selection.onConflict == .overwrite else {
                            skipped.append(EnvImportSkipModel(selection, name: name, reason: .existingItem))
                            continue
                        }
                        try batch.editValue(existing.id, value: candidate.value)
                        overwritten.append(name)
                    } else {
                        try batch.add(scope: scope, kind: selection.kind, name: name, value: candidate.value)
                        added.append(name)
                    }
                    if candidate.didStripTrailingNewlines {
                        stripped.append(name)
                    }
                }
            }
        } catch {
            throw .config(error)
        }
        Self.log.info(
            """
            Imported \(added.count, privacy: .public) new and \(overwritten.count, privacy: .public) \
            overwritten item(s) from a .env file
            """
        )
        return EnvImportResultModel(added: added, overwritten: overwritten, skipped: skipped, strippedTrailingNewlines: stripped)
    }

    // MARK: - Export

    /// The names an export of `scope` writes and leaves out (no decryption).
    public func exportPreview(repositoryID: RepoID, scope: ConfigScope) throws(EnvFileError) -> EnvExportPreviewModel {
        try exportPreview(place: .scope(repositoryID: repositoryID, scope: scope))
    }

    /// The names an export of a scope or folder (v0.7.0) writes and leaves out (no decryption).
    public func exportPreview(place: ItemPlaceModel) throws(EnvFileError) -> EnvExportPreviewModel {
        do {
            switch place {
            case .scope(let repositoryID, let scope):
                let items = try ConfigStore(database: session.database).fetchItems(repositoryID: repositoryID, scope: scope)
                return Self.preview(of: items)
            case .folder(let folderID):
                let items = try FolderStore(database: session.database).fetchItems(folderID: folderID)
                return Self.preview(of: items.map {
                    ExportCandidate(kind: $0.kind, name: $0.name, nameKey: $0.nameKey, hasValue: true, isDeleted: false)
                })
            case .destination(let destinationID):
                let items = try DestinationStore(database: session.database).fetchItems(destinationID: destinationID)
                return Self.preview(of: items.map {
                    ExportCandidate(kind: $0.kind, name: $0.name, nameKey: $0.nameKey, hasValue: $0.hasValue, isDeleted: $0.isDeleted)
                })
            }
        } catch {
            throw .config(.wrap(error))
        }
    }

    /// iCloud and git warnings for a destination chosen in the save panel (§5.13). A failing git
    /// check is reported as unknown, never as safe.
    public func inspectDestination(_ fileURL: URL) async -> EnvExportDestinationModel {
        let cloud = cloudSyncDetector.status(for: fileURL)
        let exposure = try? await GitExposureInspector.inspect(fileURL: fileURL, using: gitignoreChecker)
        return EnvExportDestinationModel(cloudSyncStatus: cloud, gitExposure: exposure)
    }

    /// Writes `scope` as a `.env` file at `fileURL` (mode 0600, never through a symlink).
    ///
    /// - Parameters:
    ///   - authorization: from `ReauthGate.authorizeEnvExport(with:session:)`; consumed here.
    ///   - headerComments: optional `# ` lines the app supplies (localized).
    /// - Throws: `.authorizationInvalid`, `.config`, `.serialize`, `.write`.
    @discardableResult
    public func export(
        repositoryID: RepoID,
        scope: ConfigScope,
        to fileURL: URL,
        authorization: EnvExportAuthorizationModel,
        existingFile: SecureFileWriter.ExistingFilePolicy = .fail,
        headerComments: [String] = []
    ) throws(EnvFileError) -> EnvExportResultModel {
        try export(
            place: .scope(repositoryID: repositoryID, scope: scope),
            to: fileURL,
            authorization: authorization,
            existingFile: existingFile,
            headerComments: headerComments
        )
    }

    /// Writes a scope or a folder (v0.7.0) as a `.env` file at `fileURL` (mode 0600, never
    /// through a symlink), under the same rules as a scope export.
    @discardableResult
    public func export(
        place: ItemPlaceModel,
        to fileURL: URL,
        authorization: EnvExportAuthorizationModel,
        existingFile: SecureFileWriter.ExistingFilePolicy = .fail,
        headerComments: [String] = []
    ) throws(EnvFileError) -> EnvExportResultModel {
        try authorization.consume(.file, for: session)
        let preview = try exportPreview(place: place)
        let contents = try serialize(place: place, names: Set(preview.exportedNames), headerComments: headerComments)
        defer { contents.wipe() }
        do {
            try fileWriter.write(contents, to: fileURL, existingFile: existingFile)
        } catch {
            throw .write(error)
        }
        Self.log.info("Exported \(preview.exportedNames.count, privacy: .public) item(s) to a .env file")
        return EnvExportResultModel(fileURL: fileURL, preview: preview)
    }

    /// Appends the exact ignore line for `relativePath` to `<repositoryRoot>/.gitignore` (the
    /// offer after an export to a non-ignored path). Returns false when an equivalent entry is
    /// already in force. An existing file keeps its mode; a new one gets 0644.
    @discardableResult
    public func addGitignoreEntry(relativePath: String, repositoryRoot: URL) throws(EnvFileError) -> Bool {
        let url = GitignoreEditor.gitignoreURL(repositoryRoot: repositoryRoot)
        let path = url.path(percentEncoded: false)
        var info = stat()
        let exists = lstat(path, &info) == 0
        if exists, info.st_mode & S_IFMT != S_IFREG {
            throw .gitignoreNotRegularFile
        }
        var existing: String?
        if exists {
            guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
                throw .gitignoreUnreadable
            }
            existing = text
        }
        guard let updated = GitignoreEditor.contents(byAddingEntryForRelativePath: relativePath, to: existing) else {
            return false
        }
        do {
            try fileWriter.write(Data(updated.utf8), to: url, existingFile: .replace)
        } catch {
            throw .write(error)
        }
        let mode = exists ? info.st_mode & ~S_IFMT : Self.gitignoreFileMode
        if chmod(path, mode) != 0 {
            throw .write(.systemCall(.setPermissions, errno: errno))
        }
        return true
    }

    // MARK: - Private

    /// ``applyImport(_:selections:place:)`` into a folder: one transaction, final.
    private func applyFolderImport(
        _ preview: EnvImportPreviewModel,
        selections: [EnvImportSelectionModel],
        folderID: FolderID
    ) throws(EnvFileError) -> EnvImportResultModel {
        var added: [String] = []
        var overwritten: [String] = []
        var skipped: [EnvImportSkipModel] = []
        var stripped: [String] = []
        do throws(ConfigRepositoryError) {
            try folders.write { keys, tx, now in
                let writer = FolderItemWriter(store: FolderStore(database: session.database), keys: keys, tx: tx, now: now)
                _ = try writer.requireFolder(folderID)
                var seen: Set<String> = []
                for selection in selections {
                    let name: String
                    let candidate: EnvImportCandidateModel
                    switch Self.resolve(selection, in: preview, seen: &seen) {
                    case .accepted(let validName, let accepted):
                        (name, candidate) = (validName, accepted)
                    case .skipped(let skip):
                        skipped.append(skip)
                        continue
                    }
                    if let existing = try writer.row(folderID: folderID, kind: selection.kind, name: name) {
                        guard selection.onConflict == .overwrite else {
                            skipped.append(EnvImportSkipModel(selection, name: name, reason: .existingItem))
                            continue
                        }
                        try writer.editValue(existing.id, value: candidate.value)
                        overwritten.append(name)
                    } else {
                        try writer.add(folderID: folderID, kind: selection.kind, name: name, value: candidate.value)
                        added.append(name)
                    }
                    if candidate.didStripTrailingNewlines {
                        stripped.append(name)
                    }
                }
            }
        } catch {
            throw .config(error)
        }
        Self.log.info("Imported \(added.count, privacy: .public) new and \(overwritten.count, privacy: .public) overwritten item(s) into a folder")
        return EnvImportResultModel(added: added, overwritten: overwritten, skipped: skipped, strippedTrailingNewlines: stripped)
    }

    /// Imports into a destination (v0.8.0): pending changes for the next Sync, existing names
    /// skipped or overwritten; variables become secrets where the provider holds secrets only.
    private func applyDestinationImport(
        _ preview: EnvImportPreviewModel,
        selections: [EnvImportSelectionModel],
        destinationID: DestinationID
    ) throws(EnvFileError) -> EnvImportResultModel {
        var added: [String] = []
        var overwritten: [String] = []
        var skipped: [EnvImportSkipModel] = []
        var stripped: [String] = []
        do throws(ConfigRepositoryError) {
            try destinations.write { keys, tx, now in
                let writer = DestinationItemWriter(store: DestinationStore(database: session.database), keys: keys, tx: tx, now: now)
                _ = try writer.requireDestination(destinationID)
                var seen: Set<String> = []
                for selection in selections {
                    let name: String
                    let candidate: EnvImportCandidateModel
                    switch Self.resolve(selection, in: preview, seen: &seen) {
                    case .accepted(let validName, let accepted):
                        (name, candidate) = (validName, accepted)
                    case .skipped(let skip):
                        skipped.append(skip)
                        continue
                    }
                    if let existing = try writer.liveRow(destinationID: destinationID, name: name) {
                        guard selection.onConflict == .overwrite else {
                            skipped.append(EnvImportSkipModel(selection, name: name, reason: .existingItem))
                            continue
                        }
                        try writer.editValue(existing.id, value: candidate.value)
                        overwritten.append(name)
                    } else {
                        try writer.add(destinationID: destinationID, kind: selection.kind, name: name, value: candidate.value)
                        added.append(name)
                    }
                    if candidate.didStripTrailingNewlines {
                        stripped.append(name)
                    }
                }
            }
        } catch {
            throw .config(error)
        }
        Self.log.info("Imported \(added.count, privacy: .public) new and \(overwritten.count, privacy: .public) overwritten item(s) into a destination")
        return EnvImportResultModel(added: added, overwritten: overwritten, skipped: skipped, strippedTrailingNewlines: stripped)
    }

    /// One selection after validation.
    private enum SelectionResolution {
        case accepted(name: String, candidate: EnvImportCandidateModel)
        case skipped(EnvImportSkipModel)
    }

    /// The validated name and candidate of one selection, or why it is skipped.
    private static func resolve(
        _ selection: EnvImportSelectionModel,
        in preview: EnvImportPreviewModel,
        seen: inout Set<String>
    ) -> SelectionResolution {
        guard preview.candidates.indices.contains(selection.candidateIndex) else {
            return .skipped(EnvImportSkipModel(selection, name: selection.name, reason: .unknownCandidate))
        }
        let candidate = preview.candidates[selection.candidateIndex]
        let name: String
        do throws(ValidationError) {
            name = try GitHubNameValidator.validate(selection.name)
        } catch {
            return .skipped(EnvImportSkipModel(selection, name: selection.name, reason: .invalidName(error)))
        }
        if let problem = candidate.valueProblem {
            return .skipped(EnvImportSkipModel(selection, name: name, reason: .invalidValue(problem)))
        }
        guard seen.insert("\(selection.kind.rawValue)|\(name)").inserted else {
            return .skipped(EnvImportSkipModel(selection, name: name, reason: .duplicateInImport))
        }
        return .accepted(name: name, candidate: candidate)
    }

    /// What an export decides on for one item (repository or folder).
    struct ExportCandidate {
        let kind: ConfigKind
        let name: String
        let nameKey: String
        let hasValue: Bool
        let isDeleted: Bool
    }

    static func preview(of items: [ConfigItemModel]) -> EnvExportPreviewModel {
        preview(of: items.map {
            ExportCandidate(kind: $0.kind, name: $0.name, nameKey: $0.nameKey, hasValue: $0.hasValue, isDeleted: $0.isDeleted)
        })
    }

    static func preview(of items: [ExportCandidate]) -> EnvExportPreviewModel {
        var exported: [String] = []
        var valueMissing: [String] = []
        var collisions: [String] = []
        var taken: Set<String> = []
        // Secrets first, so a variable of the same name is the one left out.
        let live = items.filter { !$0.isDeleted }.sorted { lhs, rhs in
            (lhs.kind == .secret ? 0 : 1, lhs.name) < (rhs.kind == .secret ? 0 : 1, rhs.name)
        }
        for item in live {
            guard item.hasValue else {
                valueMissing.append(item.name)
                continue
            }
            guard taken.insert(item.nameKey).inserted else {
                collisions.append(item.name)
                continue
            }
            exported.append(item.name)
        }
        return EnvExportPreviewModel(
            exportedNames: exported.sorted(),
            valueMissingNames: valueMissing.sorted(),
            nameCollisions: collisions.sorted()
        )
    }

    /// Decrypts the exported items of a scope or folder and serializes them in name order.
    private func serialize(
        place: ItemPlaceModel,
        names: Set<String>,
        headerComments: [String]
    ) throws(EnvFileError) -> SecretBytes {
        let entries: [DotEnvEntryModel]
        do {
            entries = try session.read { keys, tx in
                let sources = try itemSources(of: place, in: tx)
                var byName: [String: DotEnvEntryModel] = [:]
                let ordered = sources.filter { !$0.isDeleted && names.contains($0.name) }
                    .sorted { ($0.kind == .secret ? 0 : 1) < ($1.kind == .secret ? 0 : 1) }
                for source in ordered where byName[source.name] == nil {
                    guard let value = try source.openValue(keys: keys) else { continue }
                    byName[source.name] = DotEnvEntryModel(key: source.name, value: value)
                }
                return byName.keys.sorted().compactMap { byName[$0] }
            }
        } catch {
            throw .config(.wrap(error))
        }
        defer { entries.forEach { $0.value.wipe() } }
        do {
            return try DotEnvSerializer.serialize(entries, headerComments: headerComments)
        } catch {
            throw .serialize(error)
        }
    }

    /// The rows of a scope, folder or destination, tombstones included.
    private func itemSources(of place: ItemPlaceModel, in tx: StoreTransaction) throws -> [ItemCopySource] {
        switch place {
        case .scope(let repositoryID, let scope):
            try ConfigStore(database: session.database)
                .fetchItemRecords(repositoryID: repositoryID, scope: scope, in: tx)
                .map(ItemCopySource.init)
        case .folder(let folderID):
            try FolderStore(database: session.database).fetchItemRecords(folderID: folderID, in: tx).map(ItemCopySource.init)
        case .destination(let destinationID):
            try DestinationStore(database: session.database)
                .fetchItemRecords(destinationID: destinationID, in: tx)
                .map(ItemCopySource.init)
        }
    }

    // MARK: - Copy All

    /// Copy All's text (board Main2-Repository): a `# <sectionTitle>` section per kind, secrets
    /// first, names in order, every live item; a value the vault lacks is `KEY=`. Consumes a
    /// ``EnvExportPurpose/clipboard`` authorization and logs nothing; the caller wipes the text.
    /// Throws `.authorizationInvalid`, `.config` or `.serialize`.
    public func copyAllText(
        of place: ItemHolderModel,
        authorization: EnvExportAuthorizationModel,
        sectionTitle: (ConfigKind, Int) -> String
    ) throws(EnvFileError) -> CopyAllTextModel {
        try authorization.consume(.clipboard, for: session)
        let byKind: [ConfigKind: [DotEnvEntryModel]]
        let valueCount: Int
        do {
            (byKind, valueCount) = try session.read { keys, tx in
                var byKind: [ConfigKind: [DotEnvEntryModel]] = [:]
                var valueCount = 0
                func add(_ kind: ConfigKind, _ name: String, _ value: SecretBytes?) {
                    if value != nil { valueCount += 1 }
                    byKind[kind, default: []].append(DotEnvEntryModel(key: name, value: value ?? SecretBytes(count: 0)))
                }
                switch place {
                case .place(let place):
                    for source in try itemSources(of: place, in: tx) where !source.isDeleted {
                        add(source.kind, source.name, try source.openValue(keys: keys))
                    }
                case .organization(let organizationID):
                    let records = try OrganizationStore(database: session.database)
                        .fetchItemRecords(organizationID: organizationID, in: tx)
                    for record in records where !record.isDeleted {
                        add(record.kind, record.name, try OrgFieldCipher.openValue(of: record, keys: keys))
                    }
                }
                return (byKind, valueCount)
            }
        } catch {
            throw .config(.wrap(error))
        }
        defer { byKind.values.joined().forEach { $0.value.wipe() } }
        let sections = ConfigKind.allCases.compactMap { kind -> DotEnvSectionModel? in
            guard let entries = byKind[kind], !entries.isEmpty else { return nil }
            return DotEnvSectionModel(comments: [sectionTitle(kind, entries.count)], entries: entries.sorted { $0.key < $1.key })
        }
        do {
            return CopyAllTextModel(text: try DotEnvSerializer.serialize(sections: sections), valueCount: valueCount)
        } catch {
            throw .serialize(error)
        }
    }
}

/// Copy All's dotenv text and how many of its lines carry a value (a secret without one is `KEY=`).
public struct CopyAllTextModel: Sendable {
    public let text: SecretBytes
    public let valueCount: Int
}
