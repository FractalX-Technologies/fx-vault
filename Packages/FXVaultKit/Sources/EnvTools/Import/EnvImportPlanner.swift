import VaultCore

/// One `.env` entry prepared for import: name proposal, secret pre-mark and normalized value
/// (M5 `EnvImportScreen`).
public struct EnvImportCandidateModel: Sendable {
    /// 1-based line of the entry in the file.
    public let line: Int
    /// The key check and its proposed fix.
    public let key: KeyNormalizationModel
    /// The GitHub name to import under: ``KeyNormalizationModel/proposedKey`` made unique
    /// within the file, or nil when the user must type one.
    public let proposedName: String?
    /// Set when the key's proposed name folds to the same GitHub name as an earlier entry's
    /// (`db_url` and `DB_URL`, `api-key` and `api_key`): that entry's line. This candidate then
    /// gets a `_2`-style suffix and needs review.
    public let collidesWithLine: Int?
    /// Why the entry looks like a credential (key and value heuristics, §5.13).
    public let credential: CredentialAssessmentModel
    /// The value with trailing CR/LF removed (D32), in a buffer this candidate owns.
    public let value: SecretBytes
    /// True when trailing CR/LF was removed; the screen shows a notice.
    public let didStripTrailingNewlines: Bool
    /// ``ValidationError/emptyValue`` or ``ValidationError/valueTooLarge(limit:)`` when the
    /// value cannot be pushed as is.
    public let valueProblem: ValidationError?

    /// The kind the screen pre-selects: secret when the entry looks like a credential.
    public var suggestedKind: ConfigKind {
        credential.suggestedKind
    }

    /// True when the user must look at this row before importing (a fixed or missing name, a
    /// collision, or a value problem).
    public var needsReview: Bool {
        key.needsReview || proposedName == nil || collidesWithLine != nil || valueProblem != nil
    }
}

/// Combines ``DotEnvParser`` output with ``KeyNormalizer``, ``CredentialClassifier`` and
/// `ValueNormalizer` (D32). Pure: no I/O, no storage.
public enum EnvImportPlanner {
    /// One candidate per parsed entry, in file order.
    ///
    /// The caller owns the parse result's buffers and each candidate's `value`; all of them are
    /// wiped when released.
    public static func plan(_ result: DotEnvParseResult) -> [EnvImportCandidateModel] {
        var takenKeys = Set<String>()
        var lineByFoldKey: [String: Int] = [:]
        var candidates: [EnvImportCandidateModel] = []

        for entry in result.entries {
            let line = entry.line ?? 0
            let normalization = KeyNormalizer.normalize(entry.key)

            var proposedName = normalization.proposedKey
            var collidesWithLine: Int?
            if let proposed = proposedName {
                let foldKey = GitHubNameValidator.foldKey(proposed)
                if takenKeys.contains(foldKey) {
                    collidesWithLine = lineByFoldKey[foldKey]
                    proposedName = KeyNormalizer.uniqueKey(from: proposed, avoiding: takenKeys)
                }
            }
            if let name = proposedName {
                let foldKey = GitHubNameValidator.foldKey(name)
                takenKeys.insert(foldKey)
                lineByFoldKey[foldKey] = line
            }

            let keptCount = entry.value.withUnsafeBytes { bytes in
                bytes.count - ValueNormalizer.trailingNewlineCount(in: bytes)
            }
            let value = entry.value.prefix(keptCount)
            var valueProblem: ValidationError?
            do throws(ValidationError) {
                try ValueNormalizer.validate(byteCount: keptCount)
            } catch {
                valueProblem = error
            }

            candidates.append(
                EnvImportCandidateModel(
                    line: line,
                    key: normalization,
                    proposedName: proposedName,
                    collidesWithLine: collidesWithLine,
                    credential: CredentialClassifier.assess(key: entry.key, value: value),
                    value: value,
                    didStripTrailingNewlines: keptCount != entry.value.count,
                    valueProblem: valueProblem
                )
            )
        }
        return candidates
    }
}
