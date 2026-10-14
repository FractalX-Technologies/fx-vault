/// One deployment branch or tag pattern (`deployment_branch_patterns` row, §6 `v5`).
public struct BranchPatternModel: Sendable, Hashable, Identifiable {
    public var id: BranchPatternID
    public var environmentID: EnvironmentID
    /// fnmatch-style pattern, 1–255 characters, validated by ``BranchPatternValidator``.
    public var pattern: String
    public var type: BranchPatternType
    /// GitHub's policy id once posted. Reset to nil when the policy leaves custom.
    public var githubPolicyID: Int64?
    /// Tombstone pending deletion on GitHub.
    public var isDeleted: Bool

    public init(
        id: BranchPatternID = BranchPatternID(),
        environmentID: EnvironmentID,
        pattern: String,
        type: BranchPatternType,
        githubPolicyID: Int64? = nil,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.environmentID = environmentID
        self.pattern = pattern
        self.type = type
        self.githubPolicyID = githubPolicyID
        self.isDeleted = isDeleted
    }

    /// True once GitHub has the pattern.
    public var isSynced: Bool {
        githubPolicyID != nil
    }
}

/// `deployment_branch_patterns.type`.
public enum BranchPatternType: String, Sendable, Hashable, Codable, CaseIterable {
    case branch
    case tag
}
