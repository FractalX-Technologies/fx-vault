import EnvTools
import VaultCore

/// A parsed `.env` file ready for the import table (M5 `EnvImportScreen`): one candidate per
/// entry with its proposed name, pre-marked kind and normalized value, plus the parse issues.
public struct EnvImportPreviewModel: Sendable {
    public let candidates: [EnvImportCandidateModel]
    public let issues: [EnvParseIssue]

    public init(candidates: [EnvImportCandidateModel], issues: [EnvParseIssue]) {
        self.candidates = candidates
        self.issues = issues
    }

    /// The table's initial rows: every candidate with a proposed name and a usable value, under
    /// its proposed name and suggested kind (credential pre-marking, §5.13), skipping conflicts.
    public var defaultSelections: [EnvImportSelectionModel] {
        candidates.indices.compactMap { index in
            let candidate = candidates[index]
            guard let name = candidate.proposedName, candidate.valueProblem == nil else { return nil }
            return EnvImportSelectionModel(candidateIndex: index, name: name, kind: candidate.suggestedKind, onConflict: .skip)
        }
    }

    /// Wipes every candidate's value. Call it when the import sheet closes.
    public func wipe() {
        candidates.forEach { $0.value.wipe() }
    }
}

/// What to do when the target scope already has a live item of the same name and kind.
public enum EnvImportConflictChoice: String, Sendable, Hashable, CaseIterable {
    /// Keep the existing value.
    case skip
    /// Replace the existing value (a pending modification when it is synced).
    case overwrite
}

/// One row the user chose to import: which candidate, under which name and kind, and the
/// conflict choice (§10 `EnvImportScreen`: Key, Kind, Conflict, Target scope).
public struct EnvImportSelectionModel: Sendable, Hashable {
    /// Index into ``EnvImportPreviewModel/candidates``.
    public var candidateIndex: Int
    /// The GitHub name (validated and uppercased on import).
    public var name: String
    public var kind: ConfigKind
    public var onConflict: EnvImportConflictChoice

    public init(candidateIndex: Int, name: String, kind: ConfigKind, onConflict: EnvImportConflictChoice) {
        self.candidateIndex = candidateIndex
        self.name = name
        self.kind = kind
        self.onConflict = onConflict
    }
}

/// A selection that was not imported, and why.
public struct EnvImportSkipModel: Sendable, Hashable {
    public enum Reason: Sendable, Hashable {
        /// The name breaks GitHub's rules.
        case invalidName(ValidationError)
        /// The value is empty or too large after normalization (D32).
        case invalidValue(ValidationError)
        /// Another selection already imports this name and kind.
        case duplicateInImport
        /// A live item of this name and kind exists and the choice was ``EnvImportConflictChoice/skip``.
        case existingItem
        /// The index does not name a candidate of the preview.
        case unknownCandidate
    }

    public let candidateIndex: Int
    public let name: String
    public let reason: Reason

    public init(candidateIndex: Int, name: String, reason: Reason) {
        self.candidateIndex = candidateIndex
        self.name = name
        self.reason = reason
    }

    init(_ selection: EnvImportSelectionModel, name: String, reason: Reason) {
        self.init(candidateIndex: selection.candidateIndex, name: name, reason: reason)
    }
}

/// What an import changed (names only, never values).
public struct EnvImportResultModel: Sendable, Hashable {
    /// New rows (or revived tombstones).
    public let added: [String]
    /// Existing rows whose value was replaced.
    public let overwritten: [String]
    public let skipped: [EnvImportSkipModel]
    /// Names whose value lost trailing CR/LF (D32 notice).
    public let strippedTrailingNewlines: [String]

    public init(added: [String], overwritten: [String], skipped: [EnvImportSkipModel], strippedTrailingNewlines: [String]) {
        self.added = added
        self.overwritten = overwritten
        self.skipped = skipped
        self.strippedTrailingNewlines = strippedTrailingNewlines
    }
}
