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
public struct EnvFileRepository: Sendable {
    public let session: VaultSession
    private let config: ConfigRepository
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
        self.gitignoreChecker = gitignoreChecker
        self.cloudSyncDetector = cloudSyncDetector
        self.fileWriter = fileWriter
    }

    // MARK: - Import

    /// Reads and plans a `.env` file. The file's bytes are wiped after parsing.
    ///
    /// - Throws: `.parse(.fileTooLarge)` above `EnvToolsLimits.maxEnvFileBytes`,
    ///   `.fileUnreadable`.
    public func readFile(at url: URL) throws(EnvFileError) -> EnvImportPreviewModel {
        let size: Int
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
            size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        } catch {
            throw .fileUnreadable
        }
        guard size <= EnvToolsLimits.maxEnvFileBytes else {
            throw .parse(.fileTooLarge(limit: EnvToolsLimits.maxEnvFileBytes))
        }
        var data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .fileUnreadable
        }
        let contents = SecretBytes(wipingSource: &data)
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
        do {
            let items = try ConfigStore(database: session.database).fetchItems(repositoryID: repositoryID, scope: scope)
            return Self.preview(of: items)
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
        try authorization.consume(for: session)
        let preview = try exportPreview(repositoryID: repositoryID, scope: scope)
        let contents = try serialize(
            repositoryID: repositoryID,
            scope: scope,
            names: Set(preview.exportedNames),
            headerComments: headerComments
        )
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

    static func preview(of items: [ConfigItemModel]) -> EnvExportPreviewModel {
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

    /// Decrypts the exported items and serializes them in name order.
    private func serialize(
        repositoryID: RepoID,
        scope: ConfigScope,
        names: Set<String>,
        headerComments: [String]
    ) throws(EnvFileError) -> SecretBytes {
        let entries: [DotEnvEntryModel]
        do {
            entries = try session.read { keys, tx in
                let records = try ConfigStore(database: session.database)
                    .fetchItemRecords(repositoryID: repositoryID, scope: scope, in: tx)
                var byName: [String: DotEnvEntryModel] = [:]
                let ordered = records.filter { !$0.isDeleted && names.contains($0.name) }
                    .sorted { ($0.kind == .secret ? 0 : 1) < ($1.kind == .secret ? 0 : 1) }
                for record in ordered where byName[record.name] == nil {
                    guard let value = try ConfigFieldCipher.openValue(of: record, keys: keys) else { continue }
                    byName[record.name] = DotEnvEntryModel(key: record.name, value: value)
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
}
