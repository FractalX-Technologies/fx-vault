import VaultCore

extension BranchPatternType {
    /// "Branch" or "Tag" (`BranchPolicyEditorView`).
    var policyEditorTitle: String {
        switch self {
        case .branch: String(localized: "branchPolicy.type.branch", defaultValue: "Branch")
        case .tag: String(localized: "branchPolicy.type.tag", defaultValue: "Tag")
        }
    }
}
