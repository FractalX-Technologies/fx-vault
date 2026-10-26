import VaultCore

extension BranchPatternType {
    /// "Branch" or "Tag" (`BranchPolicyEditorView`).
    var policyEditorTitle: String {
        switch self {
        case .branch: String(localized: "branchPolicy.type.branch", defaultValue: "Branch")
        case .tag: String(localized: "branchPolicy.type.tag", defaultValue: "Tag")
        }
    }

    /// "branch" or "tag" after a rule's pattern (`release/* · branch`, board NewEnvironment).
    var policyChipTitle: String {
        switch self {
        case .branch: String(localized: "branchPolicy.type.branch.chip", defaultValue: "branch")
        case .tag: String(localized: "branchPolicy.type.tag.chip", defaultValue: "tag")
        }
    }
}
