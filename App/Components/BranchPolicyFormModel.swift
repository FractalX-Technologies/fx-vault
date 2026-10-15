import Foundation
import VaultCore
import VaultData

/// The state of `BranchPolicyEditorView` (§10 `EnvironmentSettingsScreen`, M4): All branches /
/// Protected branches only / Selected patterns, with a branch|tag picker and patterns checked
/// by `BranchPatternValidator`. Pure value type; ``draft`` is what `ConfigRepository` takes.
struct BranchPolicyFormModel: Hashable {
    enum Choice: Hashable, CaseIterable {
        case all
        case protectedBranches
        case selected

        var title: String {
            switch self {
            case .all:
                String(localized: "branchPolicy.all", defaultValue: "All branches")
            case .protectedBranches:
                String(localized: "branchPolicy.protected", defaultValue: "Protected branches only")
            case .selected:
                String(localized: "branchPolicy.selected", defaultValue: "Selected branches and tags")
            }
        }
    }

    var choice: Choice
    /// Kept while another choice is selected, so switching back restores them.
    private(set) var patterns: [BranchPatternDraftModel]
    /// The pattern being typed.
    var newPattern = ""
    var newPatternType: BranchPatternType = .branch

    init(_ draft: BranchPolicyDraftModel = .all) {
        switch draft {
        case .all:
            choice = .all
            patterns = []
        case .protectedBranches:
            choice = .protectedBranches
            patterns = []
        case .custom(let drafts):
            choice = .selected
            patterns = drafts
        }
    }

    /// The policy to save.
    var draft: BranchPolicyDraftModel {
        switch choice {
        case .all: .all
        case .protectedBranches: .protectedBranches
        case .selected: .custom(patterns)
        }
    }

    // MARK: - Patterns

    private var trimmedNewPattern: String {
        newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isAtLimit: Bool {
        patterns.count >= Limits.maxBranchPatternsPerEnvironment
    }

    /// Why the typed pattern cannot be added (nothing while the field is empty).
    var newPatternNote: ConfigEditorNoteModel? {
        let pattern = trimmedNewPattern
        guard !pattern.isEmpty else { return nil }
        if let rule = BranchPatternValidator.violation(in: pattern) {
            return .error(rule.localizedMessage)
        }
        if patterns.contains(BranchPatternDraftModel(pattern: pattern, type: newPatternType)) {
            return .error(String(localized: "branchPolicy.pattern.duplicate", defaultValue: "This rule is already in the list."))
        }
        if isAtLimit {
            return .error(ConfigRepositoryError.tooManyBranchPatterns(limit: Limits.maxBranchPatternsPerEnvironment).localizedMessage)
        }
        return nil
    }

    var canAddPattern: Bool {
        choice == .selected && !trimmedNewPattern.isEmpty && newPatternNote == nil
    }

    /// Adds the typed pattern and clears the field. Returns false when it is not valid.
    @discardableResult
    mutating func addPattern() -> Bool {
        guard canAddPattern else { return false }
        patterns.append(BranchPatternDraftModel(pattern: trimmedNewPattern, type: newPatternType))
        newPattern = ""
        return true
    }

    mutating func removePattern(_ pattern: BranchPatternDraftModel) {
        patterns.removeAll { $0 == pattern }
    }

    // MARK: - Validity

    /// Every pattern is valid and within the limit (the repository checks again).
    var isValid: Bool {
        guard choice == .selected else { return true }
        return patterns.count <= Limits.maxBranchPatternsPerEnvironment
            && patterns.allSatisfy { BranchPatternValidator.isValid($0.pattern) }
    }

    /// A pattern is typed but not added yet. The sheet's primary button waits for it, so Return
    /// in the pattern field adds the rule instead of saving without it.
    var hasUnaddedPattern: Bool {
        choice == .selected && !trimmedNewPattern.isEmpty
    }

    /// Valid and nothing left in the pattern field.
    var isReadyToSave: Bool {
        isValid && !hasUnaddedPattern
    }

    /// A warning about the chosen policy, or nil.
    var warning: ConfigEditorNoteModel? {
        switch choice {
        case .all:
            nil
        case .protectedBranches:
            .warning(String(
                localized: "branchPolicy.protected.warning",
                defaultValue: "Only branches with branch protection rules can deploy. If the repository has none, no branch can deploy to this environment."
            ))
        case .selected where patterns.isEmpty:
            .warning(String(
                localized: "branchPolicy.selected.empty",
                defaultValue: "Add at least one rule. With none, no branch or tag can deploy to this environment."
            ))
        case .selected:
            nil
        }
    }
}
