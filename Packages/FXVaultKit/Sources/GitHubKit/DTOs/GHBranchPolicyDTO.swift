import Foundation
import VaultCore

/// One deployment branch or tag policy (tasks/todo.md §8 B5, C3).
public struct GHBranchPolicyDTO: Sendable, Hashable, Decodable {
    public let id: Int64
    public let name: String
    /// `branch` or `tag`; GitHub omits it on older policies, which are branch policies.
    public let type: BranchPatternType

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
    }

    public init(id: Int64, name: String, type: BranchPatternType) {
        self.id = id
        self.name = name
        self.type = type
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let rawType = try container.decodeIfPresent(String.self, forKey: .type)
        type = rawType.flatMap { BranchPatternType(rawValue: $0.lowercased()) } ?? .branch
    }
}

/// One page of `gh api --paginate --slurp .../deployment-branch-policies`.
struct GHBranchPoliciesPageDTO: Decodable {
    let branchPolicies: [GHBranchPolicyDTO]

    enum CodingKeys: String, CodingKey {
        case branchPolicies = "branch_policies"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        branchPolicies = try container.decodeIfPresent([GHBranchPolicyDTO].self, forKey: .branchPolicies) ?? []
    }
}
