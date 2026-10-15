import VaultCore

/// One branch or tag pattern as the `BranchPolicyEditor` sheet produces it (§10).
public struct BranchPatternDraftModel: Sendable, Hashable {
    public var pattern: String
    public var type: BranchPatternType

    public init(pattern: String, type: BranchPatternType) {
        self.pattern = pattern
        self.type = type
    }
}

/// The desired deployment branch policy of an environment, without row identities (§10
/// `EnvironmentSettingsScreen`). ``ConfigRepository`` maps it onto pattern rows: kept rows keep
/// their GitHub ids, removed synced rows become tombstones, removed unsynced rows are deleted.
public enum BranchPolicyDraftModel: Sendable, Hashable {
    /// No restriction.
    case all
    /// Protected branches only.
    case protectedBranches
    /// Selected branch and tag patterns.
    case custom([BranchPatternDraftModel])

    /// The database form.
    public var kind: BranchPolicyKind {
        switch self {
        case .all: .all
        case .protectedBranches: .protected
        case .custom: .custom
        }
    }

    /// The draft of an existing policy (tombstoned patterns left out).
    public init(_ policy: DeploymentBranchPolicyModel) {
        switch policy {
        case .all:
            self = .all
        case .protectedBranches:
            self = .protectedBranches
        case .custom:
            self = .custom(policy.activePatterns.map { BranchPatternDraftModel(pattern: $0.pattern, type: $0.type) })
        }
    }

    /// The patterns, validated and without duplicates (first occurrence wins). Empty unless
    /// ``custom(_:)``.
    ///
    /// - Throws: ``ConfigRepositoryError/validation(_:)`` for a bad pattern and
    ///   ``ConfigRepositoryError/tooManyBranchPatterns(limit:)`` above
    ///   `Limits.maxBranchPatternsPerEnvironment`.
    func validatedPatterns() throws(ConfigRepositoryError) -> [BranchPatternDraftModel] {
        guard case .custom(let drafts) = self else { return [] }
        var seen: Set<BranchPatternDraftModel> = []
        var result: [BranchPatternDraftModel] = []
        for draft in drafts {
            do {
                try BranchPatternValidator.validate(draft.pattern)
            } catch {
                throw .validation(error)
            }
            if seen.insert(draft).inserted {
                result.append(draft)
            }
        }
        if result.count > Limits.maxBranchPatternsPerEnvironment {
            throw .tooManyBranchPatterns(limit: Limits.maxBranchPatternsPerEnvironment)
        }
        return result
    }
}
