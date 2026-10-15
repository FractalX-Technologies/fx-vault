import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// The nested editors of New Repository: one staged secret or variable, and one staged
/// environment with its deployment branch policy.
@MainActor
@Suite("Create repository editors")
struct CreateRepoEditorTests {
    static let value = "FXV_FIXTURE_EDITOR_VALUE"

    /// Records what an editor handed back.
    @MainActor
    final class SaveRecorder<Saved> {
        var saved: [Saved] = []
    }

    static func itemEditor(
        target: CreateRepoItemTargetModel = .repository,
        editing item: CreateRepoItemDraftModel? = nil,
        kind: ConfigKind = .secret,
        siblings: [CreateRepoItemDraftModel] = [],
        recorder: SaveRecorder<CreateRepoItemDraftModel>
    ) -> CreateRepoItemEditorViewModel {
        CreateRepoItemEditorViewModel(
            target: target,
            scopeTitle: "Repository",
            editing: item,
            kind: kind,
            siblings: siblings
        ) { recorder.saved.append($0) }
    }

    // MARK: - Items

    @Test func namesAreValidatedSuggestedAndUppercased() {
        let recorder = SaveRecorder<CreateRepoItemDraftModel>()
        let editor = Self.itemEditor(recorder: recorder)
        #expect(editor.isNew)
        #expect(editor.nameError == nil)
        #expect(!editor.canSave)

        editor.name = "api-token"
        editor.value = Self.value
        #expect(editor.nameError != nil)
        #expect(editor.suggestedName == "API_TOKEN")
        #expect(!editor.canSave)
        #expect(!editor.save())
        #expect(recorder.saved.isEmpty)

        editor.applySuggestedName()
        #expect(editor.nameError == nil)
        editor.name = "api_token"
        #expect(editor.canSave)
        #expect(editor.save())
        #expect(recorder.saved.map(\.name) == ["API_TOKEN"])
        #expect(recorder.saved.first?.value == Self.value)
        #expect(recorder.saved.first?.kind == .secret)
        // The editor forgets the value once handed over.
        #expect(editor.value.isEmpty)
    }

    @Test func reservedAndLeadingDigitNamesAreRejected() {
        let editor = Self.itemEditor(recorder: SaveRecorder())
        editor.value = Self.value
        editor.name = "GITHUB_TOKEN"
        #expect(editor.nameError != nil)
        #expect(editor.suggestedName == "GH_TOKEN")
        editor.name = "1PASSWORD"
        #expect(editor.nameError != nil)
        #expect(!editor.canSave)
    }

    @Test func duplicatesAreCheckedPerKindInTheSameScope() {
        let sibling = CreateRepoItemDraftModel(kind: .secret, name: "API_TOKEN", value: "x")
        let editor = Self.itemEditor(siblings: [sibling], recorder: SaveRecorder())
        editor.value = Self.value
        editor.name = "api_token"
        #expect(editor.nameError != nil)
        editor.kind = .variable
        #expect(editor.nameError == nil)
        #expect(editor.canSave)
    }

    @Test func editingKeepsTheIdentityAndIgnoresItsOwnName() {
        let recorder = SaveRecorder<CreateRepoItemDraftModel>()
        let item = CreateRepoItemDraftModel(kind: .secret, name: "API_TOKEN", value: Self.value)
        let editor = Self.itemEditor(editing: item, siblings: [item], recorder: recorder)
        #expect(!editor.isNew)
        #expect(editor.nameError == nil)
        #expect(editor.save())
        #expect(recorder.saved.first?.id == item.id)
    }

    @Test func valuesFollowTheNormalizerRules() {
        let editor = Self.itemEditor(recorder: SaveRecorder())
        editor.name = "API_TOKEN"
        #expect(!editor.canSave)
        editor.value = "\n\r\n"
        #expect(!editor.canSave)
        editor.value = String(repeating: "a", count: Limits.maxValueBytes + 1)
        #expect(editor.valueError != nil)
        #expect(!editor.canSave)
        editor.value = String(repeating: "a", count: Limits.maxValueBytes)
        #expect(editor.valueError == nil)
        #expect(editor.canSave)
    }

    @Test func aFullScopeRefusesAnotherItem() {
        let siblings = (0..<Limits.maxSecretsPerEnvironment).map { index in
            CreateRepoItemDraftModel(kind: .secret, name: "SECRET_\(index)", value: "x")
        }
        let editor = Self.itemEditor(target: .environment(UUID()), siblings: siblings, recorder: SaveRecorder())
        editor.name = "ONE_MORE"
        editor.value = Self.value
        #expect(editor.capacityError != nil)
        #expect(!editor.canSave)
        editor.kind = .variable
        #expect(editor.capacityError == nil)
        #expect(editor.canSave)
    }

    @Test func credentialLookingVariablesOfferToStaySecret() {
        let editor = Self.itemEditor(kind: .variable, recorder: SaveRecorder())
        editor.name = "DB_PASSWORD"
        editor.value = Self.value
        #expect(editor.looksLikeCredential)
        editor.makeSecret()
        #expect(editor.kind == .secret)
        #expect(!editor.looksLikeCredential)
    }

    @Test func discardDropsTheValue() {
        let editor = Self.itemEditor(recorder: SaveRecorder())
        editor.value = Self.value
        editor.discard()
        #expect(editor.value.isEmpty)
    }

    @Test func draftDescriptionsAreRedacted() {
        let item = CreateRepoItemDraftModel(kind: .secret, name: "API_TOKEN", value: Self.value)
        let environment = CreateRepoEnvironmentDraftModel(name: "production", items: [item])
        var dumped = ""
        dump(environment, to: &dumped)
        for text in [String(describing: item), String(reflecting: item), "\(environment)", dumped] {
            #expect(!text.contains(Self.value))
        }
        #expect(String(describing: item).contains("API_TOKEN"))
    }

    // MARK: - Environments

    @Test func environmentNamesAreValidatedAndUniqueByFoldKey() {
        let recorder = SaveRecorder<CreateRepoEnvironmentDraftModel>()
        let existing = CreateRepoEnvironmentDraftModel(name: "Production")
        let editor = CreateRepoEnvironmentEditorViewModel(editing: nil, otherEnvironments: [existing]) {
            recorder.saved.append($0)
        }
        #expect(editor.isNew)
        #expect(!editor.canSave)
        editor.name = "production"
        #expect(editor.nameError != nil)
        editor.name = ".."
        #expect(editor.nameError != nil)
        editor.name = "a/b"
        #expect(editor.nameError != nil)
        editor.name = " staging"
        #expect(editor.nameError != nil)
        editor.name = "staging"
        #expect(editor.nameError == nil)
        #expect(editor.save())
        #expect(recorder.saved.map(\.name) == ["staging"])
        #expect(recorder.saved.first?.policy == .all)
    }

    @Test func customPolicyNeedsValidUniqueRules() {
        let recorder = SaveRecorder<CreateRepoEnvironmentDraftModel>()
        let editor = CreateRepoEnvironmentEditorViewModel(editing: nil, otherEnvironments: []) {
            recorder.saved.append($0)
        }
        editor.name = "production"
        editor.policyForm.choice = .selected
        #expect(editor.needsPattern)
        #expect(!editor.canSave)

        editor.policyForm.newPattern = "release/*"
        #expect(editor.policyForm.canAddPattern)
        #expect(!editor.canSave, "a typed but unadded rule holds back Save")
        editor.policyForm.addPattern()
        #expect(editor.policyForm.newPattern.isEmpty)
        editor.policyForm.newPattern = "release/*"
        #expect(editor.policyForm.newPatternNote?.isError == true)
        editor.policyForm.newPatternType = .tag
        #expect(editor.policyForm.newPatternNote == nil)
        editor.policyForm.addPattern()
        editor.policyForm.newPattern = "bad\u{0007}"
        #expect(editor.policyForm.newPatternNote?.isError == true)
        #expect(!editor.policyForm.canAddPattern)
        editor.policyForm.newPattern = ""

        #expect(editor.save())
        #expect(recorder.saved.first?.policy == .custom([
            BranchPatternDraftModel(pattern: "release/*", type: .branch),
            BranchPatternDraftModel(pattern: "release/*", type: .tag),
        ]))

        let reopened = CreateRepoEnvironmentEditorViewModel(editing: recorder.saved.first, otherEnvironments: recorder.saved) { _ in }
        #expect(!reopened.isNew)
        #expect(reopened.policyForm.choice == .selected)
        #expect(reopened.policyForm.patterns.count == 2)
        #expect(reopened.nameError == nil)
        reopened.policyForm.removePattern(BranchPatternDraftModel(pattern: "release/*", type: .branch))
        #expect(reopened.policyForm.patterns.map(\.type) == [.tag])
    }

    @Test func ruleCountIsLimited() {
        let editor = CreateRepoEnvironmentEditorViewModel(editing: nil, otherEnvironments: []) { _ in }
        editor.policyForm.choice = .selected
        for index in 0..<Limits.maxBranchPatternsPerEnvironment {
            editor.policyForm.newPattern = "branch-\(index)"
            editor.policyForm.addPattern()
        }
        #expect(editor.policyForm.patterns.count == Limits.maxBranchPatternsPerEnvironment)
        editor.policyForm.newPattern = "one-more"
        #expect(editor.policyForm.newPatternNote?.isError == true)
        #expect(!editor.policyForm.canAddPattern)
    }
}
