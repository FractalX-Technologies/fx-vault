import EnvTools
import Foundation
import Observation
import VaultCore
import VaultData

/// Where the `.env` text comes from.
enum EnvImportSourceKind: Hashable, CaseIterable {
    /// A file chosen with the open panel (or passed in the context).
    case file
    /// Text pasted into a secure editor.
    case paste
}

/// The import sheet's steps.
enum EnvImportStep: Equatable {
    /// Choose a file.
    case source
    /// The paste editor above the live preview table (parsed as you type, no Review step).
    case paste
    /// The parsed file's table with Key, Kind, Conflict and the Target scope picker.
    case review
    /// What the import changed (names only).
    case done(EnvImportResultModel)
}

/// The button Return triggers on each step.
enum EnvImportDefaultAction: Equatable {
    case chooseFile
    case importRows
    case done
}

/// What survives a re-parse of the paste editor: the user's own changes to one row, keyed by
/// the row's key as written and its occurrence (``EnvImportRowKey``).
private struct EnvImportRowOverrideModel {
    var name: String?
    var kind: ConfigKind?
    var onConflict: EnvImportConflictChoice?
    var isIncluded: Bool?
}

/// A row's identity across re-parses: the key as written and how many earlier lines used it.
private struct EnvImportRowKey: Hashable {
    let originalKey: String
    let occurrence: Int
}

/// `EnvImportScreen` (§10, M5, v0.1.1): file or pasted text → table of Key (with KeyNormalizer
/// fixes), Kind (the detail tab's kind, or pre-marked by CredentialClassifier from the toolbar;
/// editable, with bulk marking), Conflict (Skip/Overwrite when the name exists, Overwrite All)
/// and Target scope (the open scope first) → `EnvFileRepository.applyImport` in one transaction.
///
/// Paste mode parses the editor's text live (``Theme/Durations/envPasteParseDebounce`` after the
/// last edit) and keeps the user's row changes across re-parses.
///
/// Values: the parsed values live only in the preview's `SecretBytes`, which are wiped on every
/// re-parse, after the import, on Start Over, when the sheet closes and on lock. Pasted text is a
/// `String` (the editor needs one); it stays in the editor while the user edits it and is
/// cleared after the import, when switching to File, when the sheet closes and on lock. Values
/// are never logged. Rows, issues and summaries hold names and line numbers only.
@Observable
final class EnvImportViewModel: LockObserving {
    /// The repository whose scopes are the targets; nil for a folder (v0.7.0).
    let repositoryID: RepoID?
    /// The folder the rows go into (v0.7.0); nil for a repository.
    let folderID: FolderID?
    private(set) var step: EnvImportStep
    var sourceKind: EnvImportSourceKind {
        didSet {
            if sourceKind != oldValue {
                sourceKindDidChange()
            }
        }
    }
    /// The pasted `.env` text (secure editor binding); re-parsed after a short pause.
    var pastedText = "" {
        didSet {
            if pastedText != oldValue {
                pastedTextDidChange()
            }
        }
    }
    /// The kind every row starts as (the detail tab), or nil for CredentialClassifier's suggestion.
    let defaultKind: ConfigKind?
    /// The kind chosen with Mark All; new rows from later edits follow it too.
    private(set) var bulkKind: ConfigKind?
    /// True when the paste editor should take focus as the sheet opens.
    let focusesPasteEditor: Bool
    /// The editor changed and the preview has not caught up yet (Import waits for it).
    private(set) var isParsePending = false
    /// Why the pasted text could not be parsed at all (shown inline, not as an alert).
    private(set) var pasteProblem: ErrorPresentationModel?
    /// The chosen file's name, or nil for pasted text.
    private(set) var sourceFileName: String?
    private(set) var rows: [EnvImportRowModel] = [] {
        didSet { cachedDuplicateRowIDs = nil }
    }
    /// Parse issues in line order.
    private(set) var issues: [EnvParseIssue] = []
    private(set) var scopeOptions: [EnvImportScopeOptionModel] = []
    private(set) var targetScope: ConfigScope
    /// Rows whose name and kind already exist in the target scope, by candidate index.
    private(set) var conflictingRowIDs: Set<Int> = []
    private(set) var isWorking = false
    var alert: ErrorPresentationModel?

    /// The parsed file: candidates with their values. Wiped by ``discardPreview()``.
    @ObservationIgnored private(set) var preview: EnvImportPreviewModel?
    /// The pending debounced parse (internal so tests can await it).
    @ObservationIgnored private(set) var parseTask: Task<Void, Never>?
    @ObservationIgnored private let envFiles: EnvFileRepository
    @ObservationIgnored private let config: ConfigRepository
    @ObservationIgnored private let folders: FolderRepository
    @ObservationIgnored private let clock: any VaultClock
    /// The user's row changes, kept across re-parses of the paste editor.
    @ObservationIgnored private var overrides: [EnvImportRowKey: EnvImportRowOverrideModel] = [:]
    /// Each row's identity across re-parses, by candidate index.
    @ObservationIgnored private var rowKeys: [Int: EnvImportRowKey] = [:]
    /// Set once the sheet closed or the vault locked; late file reads are wiped on arrival.
    @ObservationIgnored private var isDiscarded = false
    /// Bumped by every parse of the paste editor; a background parse applies only if it is
    /// still the newest.
    @ObservationIgnored private var parseGeneration = 0
    /// ``duplicateRowIDs`` for the current rows, computed once per change of `rows`.
    @ObservationIgnored private var cachedDuplicateRowIDs: Set<Int>?
    @ObservationIgnored private let tasks = TaskBag()

    init(context: EnvImportContext, dependencies: FeatureDependencies) {
        switch context.place {
        case .scope(let repositoryID, let scope):
            self.repositoryID = repositoryID
            folderID = nil
            targetScope = scope
        case .folder(let id):
            repositoryID = nil
            folderID = id
            targetScope = .repository
        }
        defaultKind = context.defaultKind
        envFiles = dependencies.envFiles
        config = dependencies.config
        folders = dependencies.folders
        clock = dependencies.clock
        var prefill: SecretBytes?
        // A file passed in the context wins over any paste start.
        let start = context.fileURL == nil ? context.start : .chooser
        switch start {
        case .chooser:
            sourceKind = .file
            step = .source
            focusesPasteEditor = false
        case .pasteEditor:
            sourceKind = .paste
            step = .paste
            focusesPasteEditor = true
        case .pasted(let buffer):
            sourceKind = .paste
            step = .paste
            focusesPasteEditor = true
            prefill = buffer.take()
        }
        dependencies.actions.addLockObserver(self)
        loadScopeOptions()
        if let prefill {
            pastedText = prefill.utf8String() ?? ""
            prefill.wipe()
            parsePastedText()
        }
        if let fileURL = context.fileURL {
            tasks.set("load", Task { [weak self] in
                await self?.loadFile(at: fileURL)
            })
        }
    }

    // MARK: - Source

    var defaultAction: EnvImportDefaultAction {
        switch step {
        case .source: .chooseFile
        case .paste, .review: .importRows
        case .done: .done
        }
    }

    /// True when the paste editor holds nothing but whitespace.
    var isPastedTextEmpty: Bool {
        pastedText.allSatisfy(\.isWhitespace)
    }

    /// Reads and plans the file off the main actor, then shows the table.
    func loadFile(at url: URL) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let envFiles = envFiles
        do {
            let preview = try await Task.detached {
                try envFiles.readFile(at: url)
            }.value
            guard !isDiscarded else {
                preview.wipe()
                return
            }
            sourceFileName = url.lastPathComponent
            apply(preview)
            step = .review
        } catch {
            alert = error.presentation
        }
    }

    /// Parses the paste editor's text now (ends the debounce early). The preview replaces the
    /// previous one, whose values are wiped; the user's row changes carry over.
    func parsePastedText() {
        parseTask?.cancel()
        parseTask = nil
        isParsePending = false
        parseGeneration += 1
        guard step == .paste, !isDiscarded else { return }
        pasteProblem = nil
        guard !isPastedTextEmpty else {
            clearPreview()
            return
        }
        let contents = SecretBytes(utf8: pastedText)
        defer { contents.wipe() }
        do {
            showParsedPaste(.success(try envFiles.parse(contents)))
        } catch {
            showParsedPaste(.failure(error))
        }
    }

    /// The debounced parse: parses and plans off the main actor (large pastes would block it),
    /// then shows the result unless the text changed, the sheet closed or another parse ran
    /// meanwhile; a stale preview is wiped.
    private func parsePastedTextInBackground() async {
        guard step == .paste, !isDiscarded, !isPastedTextEmpty else {
            parsePastedText()
            return
        }
        parseGeneration += 1
        let generation = parseGeneration
        let contents = SecretBytes(utf8: pastedText)
        let envFiles = envFiles
        let result = await Task.detached { () -> Result<EnvImportPreviewModel, any Error> in
            defer { contents.wipe() }
            do {
                return .success(try envFiles.parse(contents))
            } catch {
                return .failure(error)
            }
        }.value
        guard !Task.isCancelled, generation == parseGeneration, step == .paste, !isDiscarded else {
            if case .success(let preview) = result {
                preview.wipe()
            }
            return
        }
        parseTask = nil
        isParsePending = false
        showParsedPaste(result)
    }

    /// Shows a parse of the paste editor, or why the text could not be parsed at all.
    private func showParsedPaste(_ result: Result<EnvImportPreviewModel, any Error>) {
        pasteProblem = nil
        switch result {
        case .success(let preview):
            sourceFileName = nil
            apply(preview)
        case .failure(let error):
            clearPreview()
            pasteProblem = error.presentation
        }
    }

    /// Fills the paste editor from the clipboard (SwiftUI `PasteButton`, a user action) and
    /// parses at once. Text already in the editor is kept and the paste goes after it.
    func pasteFromClipboard(_ strings: [String]) {
        let pasted = strings.joined(separator: "\n")
        guard step == .paste, !pasted.isEmpty else { return }
        if isPastedTextEmpty {
            pastedText = pasted
        } else {
            let separator = pastedText.hasSuffix("\n") ? "" : "\n"
            pastedText += separator + pasted
        }
        parsePastedText()
    }

    /// Empties the paste editor and the preview.
    func clearPastedText() {
        pastedText = ""
        overrides = [:]
        bulkKind = nil
        parsePastedText()
    }

    /// Back to an empty source (the file chooser, or an empty paste editor); the parsed values
    /// are wiped.
    func startOver() {
        if sourceKind == .paste {
            clearPastedText()
            return
        }
        clearPreview()
        overrides = [:]
        bulkKind = nil
        sourceFileName = nil
        step = .source
    }

    // MARK: - Review

    var includedRows: [EnvImportRowModel] {
        rows.filter(\.isIncluded)
    }

    var targetOption: EnvImportScopeOptionModel? {
        scopeOptions.first { $0.scope == targetScope }
    }

    /// Why the target scope cannot take the import, or nil.
    var targetProblem: String? {
        guard let targetOption else {
            return String(localized: "envImport.target.missing", defaultValue: "This scope is no longer in the vault. Choose another one.")
        }
        guard targetOption.isEditable else {
            return String(
                localized: "envImport.target.readOnly",
                defaultValue: "This scope is read-only for your account. Choose another one."
            )
        }
        return nil
    }

    var canImport: Bool {
        guard step == .review || step == .paste, !isWorking, !isParsePending, targetProblem == nil else { return false }
        let included = includedRows
        return !included.isEmpty && included.allSatisfy { nameProblem(for: $0) == nil && $0.canInclude }
    }

    var errorIssueCount: Int {
        issues.lazy.filter { $0.severity == .error }.count
    }

    /// Where the rows go: the chosen scope, or the folder.
    var targetPlace: ItemPlaceModel? {
        if let folderID { return .folder(folderID) }
        return repositoryID.map { .scope(repositoryID: $0, scope: targetScope) }
    }

    /// True for a folder: there is no scope to choose and nothing is pending for Sync.
    var isFolder: Bool {
        folderID != nil
    }

    /// Changes the target scope. Overwrite choices were made for the old scope's items, so
    /// every row goes back to Skip and conflicts are reviewed again for the new scope.
    func selectTarget(_ scope: ConfigScope) {
        guard scope != targetScope else { return }
        targetScope = scope
        for key in overrides.keys {
            overrides[key]?.onConflict = nil
        }
        for index in rows.indices where rows[index].onConflict != .skip {
            rows[index].onConflict = .skip
        }
        refreshConflicts()
    }

    func setName(_ name: String, forRow id: Int) {
        update(id) { row, override in
            row.name = name
            override.name = name
        }
        refreshConflicts()
    }

    func useSuggestedName(forRow id: Int) {
        update(id) { row, override in
            if let suggestion = row.suggestedName {
                row.name = suggestion
                override.name = nil
            }
        }
        refreshConflicts()
    }

    func setKind(_ kind: ConfigKind, forRow id: Int) {
        update(id) { row, override in
            row.kind = kind
            override.kind = kind
        }
        refreshConflicts()
    }

    /// The warning badge's one-click fix: a credential-looking variable becomes a secret.
    func makeSecret(forRow id: Int) {
        setKind(.secret, forRow: id)
    }

    /// "Mark All as Variable / Secret": every row, and the rows later edits add, take `kind`.
    func markAll(as kind: ConfigKind) {
        bulkKind = kind
        for key in overrides.keys {
            overrides[key]?.kind = nil
        }
        for index in rows.indices {
            rows[index].kind = kind
        }
        refreshConflicts()
    }

    func setConflictChoice(_ choice: EnvImportConflictChoice, forRow id: Int) {
        update(id) { row, override in
            row.onConflict = choice
            override.onConflict = choice
        }
    }

    /// True when at least one included row would skip an existing item ("Overwrite All").
    var canOverwriteAll: Bool {
        rows.contains { $0.isIncluded && $0.onConflict == .skip && conflictingRowIDs.contains($0.id) }
    }

    /// "Overwrite All": every row that collides with an existing item replaces it.
    func overwriteAllConflicts() {
        for row in rows where conflictingRowIDs.contains(row.id) {
            setConflictChoice(.overwrite, forRow: row.id)
        }
    }

    func setIncluded(_ isIncluded: Bool, forRow id: Int) {
        update(id) { row, override in
            row.isIncluded = isIncluded && row.canInclude
            override.isIncluded = isIncluded
        }
    }

    /// Includes or excludes every importable row.
    func setAllIncluded(_ isIncluded: Bool) {
        for row in rows {
            setIncluded(isIncluded, forRow: row.id)
        }
    }

    func hasConflict(_ row: EnvImportRowModel) -> Bool {
        conflictingRowIDs.contains(row.id)
    }

    /// Why the row's name cannot be imported (GitHub's rules, or a duplicate within the
    /// import), or nil.
    func nameProblem(for row: EnvImportRowModel) -> String? {
        do throws(ValidationError) {
            _ = try GitHubNameValidator.validate(row.name)
        } catch {
            return error.localizedMessage
        }
        if row.isIncluded, duplicateRowIDs.contains(row.id) {
            return String(
                localized: "envImport.name.duplicate",
                defaultValue: "Another included row imports this name as the same kind."
            )
        }
        return nil
    }

    /// The note under the key: what KeyNormalizer changed, collisions, D32 and value problems.
    func keyNotes(for row: EnvImportRowModel) -> [String] {
        var notes: [String] = []
        switch row.keyStatus {
        case .valid:
            break
        case .uppercased:
            notes.append(String(localized: "envImport.key.uppercased", defaultValue: "From \(row.originalKey)"))
        case .needsFix(let rule):
            if row.suggestedName != nil {
                notes.append(String(
                    localized: "envImport.key.fixed",
                    defaultValue: "Fixed from \(row.originalKey): \(rule.localizedMessage)"
                ))
            } else {
                notes.append(String(
                    localized: "envImport.key.noFix",
                    defaultValue: "\(row.originalKey): \(rule.localizedMessage) Enter a name."
                ))
            }
        }
        if let line = row.collidesWithLine {
            notes.append(String(
                localized: "envImport.key.collision",
                defaultValue: "Same name as line \(line), so a number was added."
            ))
        }
        if row.didStripTrailingNewlines {
            notes.append(String(
                localized: "envImport.key.strippedNewlines",
                defaultValue: "Trailing line breaks removed (GitHub removes them too)."
            ))
        }
        if let problem = row.valueProblem {
            notes.append(String(
                localized: "envImport.key.valueProblem",
                defaultValue: "Not importable: \(problem.localizedMessage)"
            ))
        }
        return notes
    }

    /// The tooltip of the credential mark: why the row was pre-marked as a secret.
    func credentialHint(for row: EnvImportRowModel) -> String? {
        guard row.looksLikeCredential else { return nil }
        let reasons = row.credentialReasons.map(\.envImportDescription).joined(separator: " ")
        return String(localized: "envImport.credential.hint", defaultValue: "Looks like a credential. \(reasons)")
    }

    /// The warning badge when a credential-looking row is imported as a variable (plaintext on
    /// GitHub); ``makeSecret(forRow:)`` is its one-click fix.
    func kindWarning(for row: EnvImportRowModel) -> String? {
        guard row.kind == .variable, row.looksLikeCredential else { return nil }
        return String(
            localized: "envImport.kind.credentialAsVariable",
            defaultValue: "Looks like a credential. Variables are shown in plaintext on GitHub and in workflow logs."
        )
    }

    /// Imports the included rows into the target scope in one transaction.
    func importRows() {
        guard canImport, let preview, let targetPlace else { return }
        let selections = includedRows.map(\.selection)
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try envFiles.applyImport(preview, selections: selections, place: targetPlace)
            clearPreview()
            overrides = [:]
            step = .done(result)
            pastedText = ""
        } catch {
            alert = error.presentation
        }
    }

    // MARK: - Done

    /// The result as lines of names and counts (never values).
    func summaryLines(for result: EnvImportResultModel) -> [String] {
        var lines: [String] = []
        let scopeTitle = targetOption?.title ?? ""
        if !result.added.isEmpty {
            lines.append(String(
                localized: "envImport.result.added",
                defaultValue: "Added \(result.added.count) to \(scopeTitle): \(result.added.joined(separator: ", "))"
            ))
        }
        if !result.overwritten.isEmpty {
            lines.append(String(
                localized: "envImport.result.overwritten",
                defaultValue: "Replaced \(result.overwritten.count) existing values: \(result.overwritten.joined(separator: ", "))"
            ))
        }
        for skip in result.skipped {
            lines.append(String(
                localized: "envImport.result.skipped",
                defaultValue: "Skipped \(skip.name): \(skip.reason.envImportDescription)"
            ))
        }
        if !result.strippedTrailingNewlines.isEmpty {
            lines.append(String(
                localized: "envImport.result.stripped",
                defaultValue: "Trailing line breaks removed from \(result.strippedTrailingNewlines.joined(separator: ", "))."
            ))
        }
        if lines.isEmpty {
            lines.append(String(localized: "envImport.result.nothing", defaultValue: "Nothing was imported."))
        }
        return lines
    }

    /// True when the import created local changes that Sync will push (never for a folder).
    func hasPendingChanges(_ result: EnvImportResultModel) -> Bool {
        !isFolder && (!result.added.isEmpty || !result.overwritten.isEmpty)
    }

    // MARK: - Lifetime

    /// Wipes every value the sheet holds. Call it when the sheet closes.
    func discard() {
        isDiscarded = true
        tasks.cancelAll()
        parseTask?.cancel()
        parseTask = nil
        isParsePending = false
        discardPreview()
        pastedText = ""
        overrides = [:]
        rows = []
        issues = []
    }

    func vaultDidLock() {
        discard()
    }

    // MARK: - Private

    /// Shows `preview` (wiping the previous one): the tab's or bulk kind first, then the user's
    /// row changes from earlier parses.
    private func apply(_ preview: EnvImportPreviewModel) {
        discardPreview()
        self.preview = preview
        issues = preview.issues.sorted { $0.line < $1.line }
        let defaults = Dictionary(
            preview.defaultSelections.map { ($0.candidateIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var occurrences: [String: Int] = [:]
        var keys: [Int: EnvImportRowKey] = [:]
        rows = preview.candidates.indices.map { index in
            var row = EnvImportRowModel(candidateIndex: index, candidate: preview.candidates[index], selection: defaults[index])
            let occurrence = occurrences[row.originalKey, default: 0]
            occurrences[row.originalKey] = occurrence + 1
            let key = EnvImportRowKey(originalKey: row.originalKey, occurrence: occurrence)
            keys[index] = key
            if let kind = bulkKind ?? defaultKind {
                row.kind = kind
            }
            if let override = overrides[key] {
                row.name = override.name ?? row.name
                row.kind = override.kind ?? row.kind
                row.onConflict = override.onConflict ?? row.onConflict
                row.isIncluded = (override.isIncluded ?? row.isIncluded) && row.canInclude
            }
            return row
        }
        rowKeys = keys
        refreshConflicts()
    }

    /// Wipes the preview and empties the table.
    private func clearPreview() {
        discardPreview()
        rows = []
        rowKeys = [:]
        issues = []
        conflictingRowIDs = []
    }

    private func discardPreview() {
        preview?.wipe()
        preview = nil
    }

    /// Changes one row and records the change so it survives the next re-parse.
    private func update(_ id: Int, _ change: (inout EnvImportRowModel, inout EnvImportRowOverrideModel) -> Void) {
        // Rows are built in candidate order, so a row's id is usually its index.
        let directIndex = rows.indices.contains(id) && rows[id].id == id ? id : nil
        guard let index = directIndex ?? rows.firstIndex(where: { $0.id == id }) else { return }
        var override = rowKeys[id].flatMap { overrides[$0] } ?? EnvImportRowOverrideModel()
        change(&rows[index], &override)
        if let key = rowKeys[id] {
            overrides[key] = override
        }
    }

    /// Schedules the live parse ``Theme/Durations/envPasteParseDebounce`` after the last edit.
    private func pastedTextDidChange() {
        guard step == .paste, !isDiscarded else { return }
        isParsePending = true
        parseTask?.cancel()
        let clock = clock
        parseTask = Task { [weak self] in
            do {
                try await clock.sleep(for: Theme.Durations.envPasteParseDebounce)
            } catch {
                return
            }
            await self?.parsePastedTextInBackground()
        }
    }

    /// File ↔ Paste: switching away from Paste clears the editor and wipes its preview.
    private func sourceKindDidChange() {
        switch (sourceKind, step) {
        case (.paste, .source):
            step = .paste
        case (.file, .paste):
            step = .source
            parseTask?.cancel()
            parseTask = nil
            isParsePending = false
            pasteProblem = nil
            pastedText = ""
            overrides = [:]
            bulkKind = nil
            clearPreview()
        default:
            break
        }
    }

    /// Included rows that repeat an earlier included row's name and kind. Computed once per
    /// change of `rows` (``nameProblem(for:)`` runs for every row on every render).
    private var duplicateRowIDs: Set<Int> {
        if let cachedDuplicateRowIDs {
            return cachedDuplicateRowIDs
        }
        let duplicates = Self.duplicateRowIDs(in: rows)
        cachedDuplicateRowIDs = duplicates
        return duplicates
    }

    private static func duplicateRowIDs(in rows: [EnvImportRowModel]) -> Set<Int> {
        var seen: Set<String> = []
        var duplicates: Set<Int> = []
        for row in rows where row.isIncluded {
            let key = "\(row.kind.rawValue)|\(GitHubNameValidator.foldKey(row.name))"
            if !seen.insert(key).inserted {
                duplicates.insert(row.id)
            }
        }
        return duplicates
    }

    private func refreshConflicts() {
        guard let preview else {
            conflictingRowIDs = []
            return
        }
        let selections = rows.filter { !$0.name.isEmpty }.map(\.selection)
        guard let targetPlace else {
            conflictingRowIDs = []
            return
        }
        do {
            conflictingRowIDs = try envFiles.conflictingCandidates(for: selections, in: preview, place: targetPlace)
        } catch {
            conflictingRowIDs = []
            alert = error.presentation
        }
    }

    private func loadScopeOptions() {
        if let folderID {
            // A folder is its own single target.
            let name = (try? folders.folders())?.first { $0.id == folderID }?.name
            scopeOptions = name.map { [EnvImportScopeOptionModel(scope: .repository, title: $0, isEditable: true)] } ?? []
            return
        }
        guard let repositoryID else {
            scopeOptions = []
            return
        }
        do {
            let capability = try config.changeSet(repositoryID: repositoryID)?.repository.capability
            scopeOptions = try config.scopes(repositoryID: repositoryID)
                .filter { !$0.isDeleted }
                .map { summary in
                    EnvImportScopeOptionModel(
                        scope: summary.scope,
                        title: summary.title,
                        isEditable: capability?.canEditItems(at: summary.scope.level) ?? false
                    )
                }
        } catch {
            scopeOptions = []
            alert = error.presentation
        }
    }
}
