import EnvTools
import VaultCore
import VaultData

/// One row of the import table (§10 `EnvImportScreen`): Key (with the KeyNormalizer fix), Kind
/// (pre-marked by CredentialClassifier), Conflict and whether the row is imported. Holds names
/// and flags only; the value stays in the preview's `SecretBytes`.
struct EnvImportRowModel: Identifiable, Hashable {
    /// Index into ``EnvImportPreviewModel/candidates``.
    let candidateIndex: Int
    /// 1-based line of the entry in the file.
    let line: Int
    /// The key as written in the file (keys are not secret).
    let originalKey: String
    let keyStatus: KeyNormalizationModel.Status
    /// The name FX Vault proposed (made unique within the file), or nil when the user must type one.
    let suggestedName: String?
    /// The earlier line whose key folds to the same GitHub name.
    let collidesWithLine: Int?
    /// Why the entry looks like a credential; empty when it does not.
    let credentialReasons: [CredentialReason]
    /// Why the value cannot be imported (empty or too large); such rows cannot be included.
    let valueProblem: ValidationError?
    /// Trailing CR/LF were removed from the value (D32).
    let didStripTrailingNewlines: Bool

    /// The GitHub name to import under (editable).
    var name: String
    var kind: ConfigKind
    var onConflict: EnvImportConflictChoice
    var isIncluded: Bool

    var id: Int {
        candidateIndex
    }

    /// Builds the row of `candidate`, starting from the preview's default selection when it has
    /// one (credential pre-marking, proposed name, Skip on conflict).
    init(candidateIndex: Int, candidate: EnvImportCandidateModel, selection: EnvImportSelectionModel?) {
        self.candidateIndex = candidateIndex
        line = candidate.line
        originalKey = candidate.key.originalKey
        keyStatus = candidate.key.status
        suggestedName = candidate.proposedName
        collidesWithLine = candidate.collidesWithLine
        credentialReasons = candidate.credential.reasons
        valueProblem = candidate.valueProblem
        didStripTrailingNewlines = candidate.didStripTrailingNewlines
        name = selection?.name ?? candidate.proposedName ?? ""
        kind = selection?.kind ?? candidate.suggestedKind
        onConflict = selection?.onConflict ?? .skip
        isIncluded = selection != nil
    }

    /// True when the value can be imported at all.
    var canInclude: Bool {
        valueProblem == nil
    }

    /// True when the entry looks like a credential.
    var looksLikeCredential: Bool {
        !credentialReasons.isEmpty
    }

    /// The name and kind as EnvFileRepository expects them.
    var selection: EnvImportSelectionModel {
        EnvImportSelectionModel(candidateIndex: candidateIndex, name: name, kind: kind, onConflict: onConflict)
    }

    /// True when the current name differs from the suggestion (the "Use suggestion" button).
    var differsFromSuggestion: Bool {
        guard let suggestedName else { return false }
        return name != suggestedName
    }
}

/// One choice of the Target scope picker.
struct EnvImportScopeOptionModel: Identifiable, Hashable {
    let scope: ConfigScope
    /// "Repository" or the environment's name.
    let title: String
    /// False when the repository's capability does not allow item edits in this scope.
    let isEditable: Bool

    var id: ConfigScope {
        scope
    }
}
