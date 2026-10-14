import Foundation
import VaultCore

/// One environment from `gh api repos/{o}/{r}/environments[/{e}]` (tasks/todo.md §8 B3, B4).
public struct GHEnvironmentDTO: Sendable, Hashable, Decodable {
    public let id: Int64
    public let name: String
    public let createdAt: Date?
    public let updatedAt: Date?
    /// Every protection rule as GitHub returned it. Rules other than `branch_policy` are not
    /// managed by FX Vault and are stored read-only (``foreignRulesJSON``).
    public let protectionRules: [JSONValue]
    /// `null` means all branches (`.all`).
    public let deploymentBranchPolicy: GitHubBranchPolicyFlagsModel?

    private static let branchPolicyRuleType = "branch_policy"
    private static let ruleTypeKey = "type"

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case protectionRules = "protection_rules"
        case deploymentBranchPolicy = "deployment_branch_policy"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        protectionRules = try container.decodeIfPresent([JSONValue].self, forKey: .protectionRules) ?? []
        deploymentBranchPolicy = try container.decodeIfPresent(
            GitHubBranchPolicyFlagsModel.self,
            forKey: .deploymentBranchPolicy
        )
    }

    /// The policy kind: null → all, protected → protected, custom → custom.
    public var branchPolicyKind: BranchPolicyKind {
        guard let flags = deploymentBranchPolicy else { return .all }
        if flags.customBranchPolicies { return .custom }
        return flags.protectedBranches ? .protected : .all
    }

    /// True when the name passes `EnvironmentNameValidator` (invalid ones are skipped and
    /// logged on import, D29).
    public var hasValidName: Bool {
        EnvironmentNameValidator.isValid(name)
    }

    /// The rules other than `branch_policy` (reviewers, wait timers, custom app rules).
    public var foreignRules: [JSONValue] {
        protectionRules.filter { $0[Self.ruleTypeKey]?.stringValue != Self.branchPolicyRuleType }
    }

    /// ``foreignRules`` as canonical JSON, or nil when there are none.
    public var foreignRulesJSON: String? {
        let rules = foreignRules
        guard !rules.isEmpty else { return nil }
        return JSONValue.array(rules).canonicalJSONString()
    }
}

/// One page of `gh api --paginate --slurp repos/{o}/{r}/environments`.
struct GHEnvironmentsPageDTO: Decodable {
    let environments: [GHEnvironmentDTO]

    enum CodingKeys: String, CodingKey {
        case environments
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        environments = try container.decodeIfPresent([GHEnvironmentDTO].self, forKey: .environments) ?? []
    }
}
