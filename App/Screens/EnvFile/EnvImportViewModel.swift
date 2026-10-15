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
    /// Choose a file or paste text.
    case source
    /// The parsed table with Key, Kind, Conflict and the Target scope picker.
    case review
    /// What the import changed (names only).
    case done(EnvImportResultModel)
}

/// The button Return triggers on each step.
enum EnvImportDefaultAction: Equatable {
    case chooseFile
    case reviewPastedText
    case importRows
    case done
}

/// `EnvImportScreen` (§10, M5): file or pasted text → table of Key (with KeyNormalizer fixes),
/// Kind (pre-marked by CredentialClassifier, editable), Conflict (Skip/Overwrite when the name
/// exists) and Target scope → `EnvFileRepository.applyImport` in one transaction.
///
/// Values: the parsed values live only in the preview's `SecretBytes`, which are wiped after the
/// import, on Start Over, when the sheet closes and on lock. Pasted text is a `String` (the
/// editor needs one) and is cleared as soon as it is parsed, and on close and lock. Rows,
/// issues and summaries hold names and line numbers only.
@Observable
final class EnvImportViewModel: LockObserving {
    let repositoryID: RepoID
    private(set) var step: EnvImportStep = .source
    var sourceKind: EnvImportSourceKind
    /// The pasted `.env` text (secure editor binding).
    var pastedText = ""
    /// The chosen file's name, or nil for pasted text.
    private(set) var sourceFileName: String?
    private(set) var rows: [EnvImportRowModel] = []
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
    @ObservationIgnored private let envFiles: EnvFileRepository
    @ObservationIgnored private let config: ConfigRepository
    /// Set once the sheet closed or the vault locked; late file reads are wiped on arrival.
    @ObservationIgnored private var isDiscarded = false
    @ObservationIgnored private let tasks = TaskBag()

    init(context: EnvImportContext, dependencies: FeatureDependencies) {
        repositoryID = context.repositoryID
        targetScope = context.scope
        envFiles = dependencies.envFiles
        config = dependencies.config
        sourceKind = .file
        dependencies.actions.addLockObserver(self)
        loadScopeOptions()
        if let fileURL = context.fileURL {
            tasks.set("load", Task { [weak self] in
                await self?.loadFile(at: fileURL)
            })
        }
    }

    // MARK: - Source

    var canReviewPastedText: Bool {
        step == .source && !isWorking && !pastedText.allSatisfy(\.isWhitespace)
    }

    var defaultAction: EnvImportDefaultAction {
        switch step {
        case .source: sourceKind == .file ? .chooseFile : .reviewPastedText
        case .review: .importRows
        case .done: .done
        }
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
        } catch {
            alert = error.presentation
        }
    }

    /// Parses the pasted text and clears it (the parsed values now live in the preview).
    func reviewPastedText() {
        guard canReviewPastedText else { return }
        let contents = SecretBytes(utf8: pastedText)
        defer { contents.wipe() }
        do {
            let preview = try envFiles.parse(contents)
            pastedText = ""
            sourceFileName = nil
            apply(preview)
        } catch {
            alert = error.presentation
        }
    }

    /// Back to the source step; the parsed values are wiped.
    func startOver() {
        discardPreview()
        rows = []
        issues = []
        conflictingRowIDs = []
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
        guard step == .review, !isWorking, targetProblem == nil else { return false }
        let included = includedRows
        return !included.isEmpty && included.allSatisfy { nameProblem(for: $0) == nil && $0.canInclude }
    }

    var errorIssueCount: Int {
        issues.lazy.filter { $0.severity == .error }.count
    }

    func selectTarget(_ scope: ConfigScope) {
        guard scope != targetScope else { return }
        targetScope = scope
        refreshConflicts()
    }

    func setName(_ name: String, forRow id: Int) {
        update(id) { $0.name = name }
        refreshConflicts()
    }

    func useSuggestedName(forRow id: Int) {
        update(id) { row in
            if let suggestion = row.suggestedName {
                row.name = suggestion
            }
        }
        refreshConflicts()
    }

    func setKind(_ kind: ConfigKind, forRow id: Int) {
        update(id) { $0.kind = kind }
        refreshConflicts()
    }

    func setConflictChoice(_ choice: EnvImportConflictChoice, forRow id: Int) {
        update(id) { $0.onConflict = choice }
    }

    func setIncluded(_ isIncluded: Bool, forRow id: Int) {
        update(id) { row in
            row.isIncluded = isIncluded && row.canInclude
        }
    }

    /// Includes or excludes every importable row.
    func setAllIncluded(_ isIncluded: Bool) {
        for index in rows.indices {
            rows[index].isIncluded = isIncluded && rows[index].canInclude
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

    /// A warning when a credential-looking row is imported as a variable (plaintext on GitHub).
    func kindWarning(for row: EnvImportRowModel) -> String? {
        guard row.kind == .variable, row.looksLikeCredential else { return nil }
        return String(
            localized: "envImport.kind.credentialAsVariable",
            defaultValue: "Looks like a credential. Variables are shown in plaintext on GitHub and in workflow logs."
        )
    }

    /// Imports the included rows into the target scope in one transaction.
    func importRows() {
        guard canImport, let preview else { return }
        let selections = includedRows.map(\.selection)
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try envFiles.applyImport(preview, selections: selections, repositoryID: repositoryID, scope: targetScope)
            discardPreview()
            rows = []
            conflictingRowIDs = []
            step = .done(result)
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

    /// True when the import created local changes that Sync will push.
    func hasPendingChanges(_ result: EnvImportResultModel) -> Bool {
        !result.added.isEmpty || !result.overwritten.isEmpty
    }

    // MARK: - Lifetime

    /// Wipes every value the sheet holds. Call it when the sheet closes.
    func discard() {
        isDiscarded = true
        tasks.cancelAll()
        discardPreview()
        pastedText = ""
        rows = []
        issues = []
    }

    func vaultDidLock() {
        discard()
    }

    // MARK: - Private

    private func apply(_ preview: EnvImportPreviewModel) {
        discardPreview()
        self.preview = preview
        issues = preview.issues.sorted { $0.line < $1.line }
        let defaults = Dictionary(
            preview.defaultSelections.map { ($0.candidateIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        rows = preview.candidates.indices.map { index in
            EnvImportRowModel(candidateIndex: index, candidate: preview.candidates[index], selection: defaults[index])
        }
        step = .review
        refreshConflicts()
    }

    private func discardPreview() {
        preview?.wipe()
        preview = nil
    }

    private func update(_ id: Int, _ change: (inout EnvImportRowModel) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
    }

    /// Included rows that repeat an earlier included row's name and kind.
    private var duplicateRowIDs: Set<Int> {
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
        do {
            let conflicts = try envFiles.conflicts(for: selections, in: preview, repositoryID: repositoryID, scope: targetScope)
            conflictingRowIDs = Set(conflicts.keys)
        } catch {
            conflictingRowIDs = []
            alert = error.presentation
        }
    }

    private func loadScopeOptions() {
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
