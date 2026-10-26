import AppKit
import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Editing an organization's own secrets and variables (tasks/todo.md B6b3a): the item editor
/// (add, value, access) and the detail's Delete, Revert and Copy Value. Nothing reaches GitHub.
@MainActor
@Suite("Organization editing")
struct OrganizationEditingTests {
    /// Example-Org imported over the scripted lists: STRIPE_KEY (selected · 3, no value),
    /// NPM_TOKEN (all, no value) and REGION (private, eu-west).
    func imported() async throws -> (TestHarness, OrganizationModel) {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        try await OrganizationViewModelTests().scriptLists(harness)
        let result = try await harness.data.organizations.importOrganization(login: "Example-Org", accountLogin: "user-a")
        return (harness, result.organization)
    }

    func makeEditor(
        _ harness: TestHarness,
        _ organization: OrganizationModel,
        _ mode: OrgItemEditorContext.Mode
    ) async -> OrgItemEditorViewModel {
        let context = OrgItemEditorContext(organizationID: organization.id, mode: mode, repositoryCandidates: ["web", "api"])
        let editor = OrgItemEditorViewModel(context: context, dependencies: harness.dependencies(recorder: ActionRecorder()))
        await editor.load()
        return editor
    }

    func item(_ name: String, in harness: TestHarness, _ organization: OrganizationModel) async throws -> OrgItemModel {
        try #require(try await harness.data.organizations.items(of: organization.id).first { $0.name == name })
    }

    @Test func addingAVariableNeedsAFreeNameAndARepositoryForSelected() async throws {
        let (harness, organization) = try await imported()
        let editor = await makeEditor(harness, organization, .add(.variable))
        #expect(editor.loadState == .ready)
        #expect(editor.title == "New Variable")
        #expect(editor.repositoryOptions == ["api", "web"])

        editor.name = "region"
        #expect(editor.name == "REGION")
        #expect(editor.nameNote?.isError == true)
        editor.name = "zone"
        editor.value = "eu-west-1"
        editor.visibility = .selected
        #expect(editor.accessNote?.isError == true)
        #expect(!editor.canSave)

        editor.setRepository("web", selected: true)
        #expect(editor.canSave)
        #expect(editor.save())

        let added = try await item("ZONE", in: harness, organization)
        #expect(added.syncStatus == .added)
        #expect(added.visibility == .selected)
        #expect(try harness.data.organizationItems.repositories(of: added.id) == ["web"])
        #expect(editor.value.isEmpty)
    }

    @Test func editingKeepsGitHubsListUntilRepositoriesArePicked() async throws {
        let (harness, organization) = try await imported()
        let stripe = try await item("STRIPE_KEY", in: harness, organization)
        let editor = await makeEditor(harness, organization, .edit(stripe.id))
        #expect(editor.title == "STRIPE_KEY")
        #expect(editor.visibility == .selected)
        #expect(editor.offersFillChoice)
        #expect(editor.accessNote?.isError == false)
        #expect(!editor.canSave)

        // A value GitHub already has: nothing to push, GitHub's list untouched.
        editor.value = "sk_fixture"
        editor.matchesGitHub = true
        #expect(editor.save())
        let filled = try await item("STRIPE_KEY", in: harness, organization)
        #expect(filled.hasValue)
        #expect(filled.syncStatus == .synced)
        #expect(try harness.data.organizationItems.repositories(of: stripe.id).isEmpty)

        let second = await makeEditor(harness, organization, .edit(stripe.id))
        #expect(!second.offersFillChoice)
        second.setRepository("api", selected: true)
        // The view's task loads again when the sheet reappears: the choice stays.
        await second.load()
        #expect(second.selectedRepositories == ["api"])
        #expect(second.canSave)
        #expect(second.save())
        #expect(try await item("STRIPE_KEY", in: harness, organization).syncStatus == .modified)
        #expect(try harness.data.organizationItems.repositories(of: stripe.id) == ["api"])
    }

    @Test func editingAVariableLoadsItsValueAndChangesAccess() async throws {
        let (harness, organization) = try await imported()
        let region = try await item("REGION", in: harness, organization)
        let editor = await makeEditor(harness, organization, .edit(region.id))
        #expect(editor.value == "eu-west")
        #expect(!editor.canSave)

        // Locking drops the decrypted value.
        let locked = await makeEditor(harness, organization, .edit(region.id))
        locked.vaultDidLock()
        #expect(locked.value.isEmpty)

        editor.visibility = .all
        #expect(editor.canSave)
        #expect(editor.save())
        let changed = try await item("REGION", in: harness, organization)
        #expect(changed.visibility == .all)
        #expect(changed.syncStatus == .modified)
        #expect(changed.isAccessChanged)
        #expect(changed.canRevert)

        // A new value alone is modified but has nothing Revert can undo.
        let npm = try await item("NPM_TOKEN", in: harness, organization)
        try harness.data.organizationItems.setValue(npm.id, value: SecretBytes(utf8: "npm_fixture"))
        let valueOnly = try await item("NPM_TOKEN", in: harness, organization)
        #expect(valueOnly.syncStatus == .modified)
        #expect(!valueOnly.isAccessChanged)
        #expect(!valueOnly.canRevert)
    }

    @Test func detailDeletesRevertsCopiesAndOpensTheEditor() async throws {
        let (harness, organization) = try await imported()
        let recorder = ActionRecorder()
        let detail = OrganizationDetailViewModel(
            organizationID: organization.id,
            dependencies: harness.dependencies(recorder: recorder),
            organization: { organization },
            repositoryNames: { ["web"] }
        )
        #expect(await TestFixtures.eventually { detail.items.count == 3 })

        detail.add(.secret)
        #expect(recorder.presented == [.orgItemEditor(OrgItemEditorContext(
            organizationID: organization.id,
            mode: .add(.secret),
            repositoryCandidates: ["web"]
        ))])

        // A synced item waits for the confirmation, then for Sync; Revert brings it back.
        let npm = try #require(detail.rows.first { $0.name == "NPM_TOKEN" })
        detail.requestDeletion(of: [npm])
        #expect(detail.pendingDeletion == [npm])
        detail.confirmDeletion()
        #expect(await TestFixtures.eventually { detail.rows.first { $0.name == "NPM_TOKEN" }?.syncStatus == .deleted })
        // As a repository's header: the pending deletion is not counted, "without value" is
        // secrets only.
        #expect(detail.subline == "Organization · 1 secret · 1 variable · 1 without value")
        let deleted = try #require(detail.rows.first { $0.name == "NPM_TOKEN" })
        detail.edit(deleted)
        #expect(recorder.presented.count == 1)
        detail.revert([deleted])
        #expect(await TestFixtures.eventually { detail.rows.first { $0.name == "NPM_TOKEN" }?.syncStatus == .synced })

        // An add disappears at once.
        let bytes = SecretBytes(utf8: "1")
        try harness.data.organizationItems.addItem(organizationID: organization.id, kind: .variable, name: "LOCAL", value: bytes, access: .all)
        #expect(await TestFixtures.eventually { detail.rows.contains { $0.name == "LOCAL" } })
        let local = try #require(detail.rows.first { $0.name == "LOCAL" })
        detail.requestDeletion(of: [local])
        #expect(detail.pendingDeletion == nil)
        #expect(await TestFixtures.eventually { !detail.rows.contains { $0.name == "LOCAL" } })

        let region = try #require(detail.rows.first { $0.name == "REGION" })
        detail.copy(region)
        #expect(detail.alert == nil)
        #expect(harness.pasteboard.string(forType: .string) == "eu-west")
    }
}
