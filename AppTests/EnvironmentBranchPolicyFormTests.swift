import Testing
import VaultCore
import VaultData
@testable import FXVault

/// `BranchPolicyEditor`'s state (§10, M4): choices, pattern validation and the draft it saves.
@MainActor
@Suite("Branch policy form")
struct EnvironmentBranchPolicyFormTests {
    @Test func draftsMapEachChoice() {
        var form = BranchPolicyFormModel()
        #expect(form.choice == .all)
        #expect(form.draft == .all)
        form.choice = .protectedBranches
        #expect(form.draft == .protectedBranches)
        form.choice = .selected
        #expect(form.draft == .custom([]))

        let custom = BranchPolicyDraftModel.custom([BranchPatternDraftModel(pattern: "v*", type: .tag)])
        #expect(BranchPolicyFormModel(custom).choice == .selected)
        #expect(BranchPolicyFormModel(custom).draft == custom)
    }

    @Test func patternsAreTrimmedValidatedAndUnique() {
        var form = BranchPolicyFormModel()
        form.choice = .selected
        form.newPattern = "  release/*  "
        #expect(form.canAddPattern)
        let added = form.addPattern()
        #expect(added)
        #expect(form.newPattern.isEmpty)
        #expect(form.patterns == [BranchPatternDraftModel(pattern: "release/*", type: .branch)])

        form.newPattern = "release/*"
        #expect(form.newPatternNote?.isError == true, "duplicate")
        let refused = form.addPattern()
        #expect(!refused)

        // The same text as a tag is a different rule.
        form.newPatternType = .tag
        #expect(form.newPatternNote == nil)
        let addedTag = form.addPattern()
        #expect(addedTag)
        #expect(form.patterns.count == 2)

        form.newPattern = "bad\u{0007}pattern"
        #expect(form.newPatternNote?.message == NameRule.controlCharacter.localizedMessage)
        #expect(!form.canAddPattern)

        form.newPattern = "x\u{202E}y"
        #expect(form.newPatternNote?.message == NameRule.bidiCharacter.localizedMessage)

        form.newPattern = String(repeating: "a", count: Limits.maxBranchPatternLength + 1)
        #expect(form.newPatternNote?.message == NameRule.tooLong(maxLength: Limits.maxBranchPatternLength).localizedMessage)

        form.removePattern(BranchPatternDraftModel(pattern: "release/*", type: .branch))
        #expect(form.patterns == [BranchPatternDraftModel(pattern: "release/*", type: .tag)])
    }

    @Test func thePatternLimitIsEnforced() {
        var form = BranchPolicyFormModel()
        form.choice = .selected
        for index in 0..<Limits.maxBranchPatternsPerEnvironment {
            form.newPattern = "release/\(index)"
            let added = form.addPattern()
            #expect(added)
        }
        form.newPattern = "one-more"
        #expect(form.newPatternNote?.message == ConfigRepositoryError.tooManyBranchPatterns(limit: Limits.maxBranchPatternsPerEnvironment).localizedMessage)
        let refused = form.addPattern()
        #expect(!refused)
        #expect(form.isValid)
    }

    @Test func switchingChoicesKeepsThePatterns() {
        var form = BranchPolicyFormModel(.custom([BranchPatternDraftModel(pattern: "main", type: .branch)]))
        form.choice = .all
        #expect(form.draft == .all)
        form.choice = .selected
        #expect(form.draft == .custom([BranchPatternDraftModel(pattern: "main", type: .branch)]))
    }

    @Test func warningsAndUnaddedPatterns() {
        var form = BranchPolicyFormModel()
        #expect(form.warning == nil)
        form.choice = .protectedBranches
        #expect(form.warning?.tone == .warning)
        form.choice = .selected
        #expect(form.warning?.tone == .warning, "no rule means nothing can deploy")

        form.newPattern = "release/*"
        #expect(form.hasUnaddedPattern)
        #expect(!form.isReadyToSave, "Return adds the rule instead of saving without it")
        form.addPattern()
        #expect(form.isReadyToSave)
        #expect(form.warning == nil)

        // A typed pattern does not matter for other choices.
        form.newPattern = "draft"
        form.choice = .all
        #expect(!form.hasUnaddedPattern)
        #expect(form.isReadyToSave)
    }
}
