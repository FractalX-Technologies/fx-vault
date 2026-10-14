/// An environment's deployment branch restriction (§6 `environments.branch_policy`, M4).
public enum DeploymentBranchPolicyModel: Sendable, Hashable {
    /// No restriction (GitHub `deployment_branch_policy: null`).
    case all
    /// Protected branches only.
    case protectedBranches
    /// Selected branch and tag patterns. Includes tombstoned rows (`isDeleted`) still pending
    /// deletion on GitHub; use ``activePatterns`` for what the user sees.
    case custom([BranchPatternModel])

    /// The database form of the policy.
    public var kind: BranchPolicyKind {
        switch self {
        case .all: .all
        case .protectedBranches: .protected
        case .custom: .custom
        }
    }

    /// Every pattern row, including tombstones. Empty unless ``custom(_:)``.
    public var patterns: [BranchPatternModel] {
        if case .custom(let patterns) = self { return patterns }
        return []
    }

    /// Patterns that are not tombstoned. Empty unless ``custom(_:)``.
    public var activePatterns: [BranchPatternModel] {
        patterns.filter { !$0.isDeleted }
    }

    /// The `deployment_branch_policy` flags GitHub expects in an environment PUT (§8 C2).
    /// Nil means `null` (``all``).
    public var gitHubFlags: GitHubBranchPolicyFlagsModel? {
        switch self {
        case .all: nil
        case .protectedBranches:
            GitHubBranchPolicyFlagsModel(protectedBranches: true, customBranchPolicies: false)
        case .custom:
            GitHubBranchPolicyFlagsModel(protectedBranches: false, customBranchPolicies: true)
        }
    }
}

/// `environments.branch_policy` / `synced_branch_policy`.
public enum BranchPolicyKind: String, Sendable, Hashable, Codable, CaseIterable {
    case all
    case protected
    case custom
}

/// GitHub's `deployment_branch_policy` object (§8 C2). Encodes with GitHub's snake_case keys.
public struct GitHubBranchPolicyFlagsModel: Sendable, Hashable, Codable {
    public var protectedBranches: Bool
    public var customBranchPolicies: Bool

    public init(protectedBranches: Bool, customBranchPolicies: Bool) {
        self.protectedBranches = protectedBranches
        self.customBranchPolicies = customBranchPolicies
    }

    private enum CodingKeys: String, CodingKey {
        case protectedBranches = "protected_branches"
        case customBranchPolicies = "custom_branch_policies"
    }
}
