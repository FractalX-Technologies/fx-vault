import Foundation
import Testing
import SyncEngine
import VaultCore

/// §7.1 editing rules and the coalescing matrix: edits through ``ConfigItemEditPlanner``,
/// then ``ChangeSetBuilder`` on the resulting rows.
@Suite("SyncDiffTests.coalescing")
struct DiffEditPlannerTests {
    private static func value(_ text: String) -> (ConfigItemID) -> Data {
        { id in Fx.fp(text, row: id) }
    }

    private static func changes(_ outcome: ItemEditOutcomeModel, environments: [EnvironmentModel] = []) -> [String] {
        ChangeSetBuilder.build(Fx.snapshot(environments: environments, items: outcome.items)).changes.map(Describe.change)
    }

    // MARK: - Coalescing matrix

    @Test func addThenEditIsAnAdd() throws {
        let added = try ConfigItemEditPlanner(items: []).add(scope: .repository, kind: .secret, name: "api_token", fingerprint: Self.value("v1"))
        let row = try #require(added.items.first)
        let edited = try added.planner.editValue(row.id, fingerprint: Self.value("v2"))
        #expect(Self.changes(edited) == ["set_secret repo API_TOKEN new added"])
        #expect(edited.items.first?.valueFingerprint == Fx.fp("v2", row: row.id))
        // Each outcome is applied before the next edit: the add inserted, the edit updates.
        guard case .insert(let inserted, let source) = try #require(added.mutations.first), added.mutations.count == 1 else {
            Issue.record("expected one insert")
            return
        }
        #expect(inserted.name == "API_TOKEN")
        #expect(source == .newValue)
        #expect(edited.mutations == [.update(try #require(edited.items.first), value: .newValue)])
    }

    @Test func addThenDeleteRemovesTheRow() throws {
        let added = try ConfigItemEditPlanner(items: []).add(scope: .repository, kind: .variable, name: "URL", fingerprint: Self.value("x"))
        let row = try #require(added.items.first)
        let deleted = try added.planner.delete(row.id)
        #expect(deleted.items.isEmpty)
        #expect(deleted.mutations == [.remove(row.id)])
        #expect(Self.changes(deleted).isEmpty)
    }

    @Test func deleteThenReAddRevivesTheTombstone() throws {
        let synced = Fx.syncedItem("API_TOKEN", value: "v1")
        let deleted = try ConfigItemEditPlanner(items: [synced]).delete(synced.id)
        #expect(Self.changes(deleted) == ["delete_secret repo API_TOKEN deleted"])

        let sameValue = try deleted.planner.add(scope: .repository, kind: .secret, name: "API_TOKEN", fingerprint: Self.value("v1"))
        #expect(sameValue.items.map(\.id) == [synced.id])
        #expect(Self.changes(sameValue).isEmpty)

        let newValue = try deleted.planner.add(scope: .repository, kind: .secret, name: "API_TOKEN", fingerprint: Self.value("v2"))
        #expect(Self.changes(newValue) == ["set_secret repo API_TOKEN update modified"])
        #expect(newValue.mutations == [.update(try #require(newValue.items.first), value: .newValue)])
    }

    @Test func editThenRevertLeavesNothing() throws {
        let synced = Fx.syncedItem("STRIPE_KEY", value: "v1")
        let edited = try ConfigItemEditPlanner(items: [synced]).editValue(synced.id, fingerprint: Self.value("v2"))
        #expect(Self.changes(edited) == ["set_secret repo STRIPE_KEY update modified"])
        let reverted = try edited.planner.revert(synced.id)
        #expect(Self.changes(reverted).isEmpty)
        #expect(reverted.items == [synced])
        #expect(reverted.mutations == [.update(synced, value: .syncedValue)])
    }

    @Test func editBackToTheSyncedValueIsNoChange() throws {
        let synced = Fx.syncedItem("STRIPE_KEY", value: "v1")
        let edited = try ConfigItemEditPlanner(items: [synced])
            .editValue(synced.id, fingerprint: Self.value("v2"))
            .planner.editValue(synced.id, fingerprint: Self.value("v1"))
        #expect(Self.changes(edited).isEmpty)
    }

    @Test func swapThroughATemporaryNameIsTwoUpdates() throws {
        let first = Fx.syncedItem("A_KEY", value: "a")
        let second = Fx.syncedItem("B_KEY", value: "b")
        let swapped = try ConfigItemEditPlanner(items: [first, second])
            .rename(first.id, to: "TMP_KEY", fingerprint: Self.value("a"))
            .planner.rename(second.id, to: "A_KEY", fingerprint: Self.value("b"))
            .planner.rename(first.id, to: "B_KEY", fingerprint: Self.value("a"))
        #expect(Self.changes(swapped).sorted() == [
            "set_secret repo A_KEY update renamed<-B_KEY",
            "set_secret repo B_KEY update renamed<-A_KEY",
        ])
    }

    @Test func renameIntoATombstoneRevivesIt() throws {
        let source = Fx.syncedItem("A_KEY", value: "a")
        let target = Fx.syncedItem("B_KEY", value: "b")
        let outcome = try ConfigItemEditPlanner(items: [source, target])
            .delete(target.id)
            .planner.rename(source.id, to: "B_KEY", fingerprint: Self.value("a"))
        let revived = try #require(outcome.items.first { $0.id == target.id })
        let retired = try #require(outcome.items.first { $0.id == source.id })
        #expect(!revived.isDeleted)
        #expect(revived.valueFingerprint == Fx.fp("a", row: target.id))
        #expect(retired.isDeleted)
        #expect(retired.name == "A_KEY")
        #expect(outcome.mutations.contains(.update(revived, value: .movedFrom(source.id))))
        #expect(Self.changes(outcome).sorted() == [
            "delete_secret repo A_KEY deleted",
            "set_secret repo B_KEY update modified",
        ])
    }

    @Test func renameOfAnUnsyncedRowStaysAnAdd() throws {
        let draft = Fx.item("DRAFT_KEY")
        let renamed = try ConfigItemEditPlanner(items: [draft]).rename(draft.id, to: "FINAL_KEY", fingerprint: Self.value("v1"))
        #expect(Self.changes(renamed) == ["set_secret repo FINAL_KEY new added"])
    }

    @Test func renameBackToTheSyncedNameIsNoChange() throws {
        let synced = Fx.syncedItem("A_KEY")
        let outcome = try ConfigItemEditPlanner(items: [synced])
            .rename(synced.id, to: "B_KEY", fingerprint: Self.value("v1"))
            .planner.rename(synced.id, to: "a_key", fingerprint: Self.value("v1"))
        #expect(Self.changes(outcome).isEmpty)
    }

    @Test func deletingARenamedRowTombstonesItsSyncedName() throws {
        let synced = Fx.syncedItem("A_KEY")
        let outcome = try ConfigItemEditPlanner(items: [synced])
            .rename(synced.id, to: "B_KEY", fingerprint: Self.value("v1"))
            .planner.delete(synced.id)
        #expect(outcome.items.first?.name == "A_KEY")
        #expect(Self.changes(outcome) == ["delete_secret repo A_KEY deleted"])
    }

    // MARK: - Fill (§7.1, §7.8)

    @Test func fillDefaultsToWhatGitHubHas() throws {
        let missing = Fx.syncedItem("DB_PASSWORD", value: nil)
        let filled = try ConfigItemEditPlanner(items: [missing]).fill(missing.id, pushOnNextSync: false, fingerprint: Self.value("p"))
        let row = try #require(filled.items.first)
        #expect(row.hasValue)
        #expect(row.syncedFingerprint == row.valueFingerprint)
        #expect(filled.mutations == [.update(row, value: .newValueAsSynced)])
        #expect(Self.changes(filled).isEmpty)
    }

    @Test func fillWithPushIsAForcePush() throws {
        let missing = Fx.syncedItem("DB_PASSWORD", value: nil)
        let filled = try ConfigItemEditPlanner(items: [missing]).fill(missing.id, pushOnNextSync: true, fingerprint: Self.value("p"))
        #expect(Self.changes(filled) == ["set_secret repo DB_PASSWORD update force"])
    }

    @Test func fillRejectsARowWithAValue() {
        let present = Fx.syncedItem("API_TOKEN")
        #expect(throws: ItemEditError.valueNotMissing) {
            try ConfigItemEditPlanner(items: [present]).fill(present.id, pushOnNextSync: false, fingerprint: Self.value("p"))
        }
    }

    // MARK: - Convert / Move (D11)

    @Test func convertSecretToVariableCreatesARowAndATombstone() throws {
        let secret = Fx.syncedItem("API_URL", value: "u")
        let newID = ConfigItemID()
        let outcome = try ConfigItemEditPlanner(items: [secret])
            .move(secret.id, kind: .variable, scope: .repository, newID: newID, fingerprint: Self.value("u"))
        #expect(Self.changes(outcome).sorted() == [
            "delete_secret repo API_URL deleted",
            "set_variable repo API_URL new added",
        ])
        #expect(outcome.mutations.first == .insert(try #require(outcome.items.first { $0.id == newID }), value: .movedFrom(secret.id)))
    }

    @Test func moveToAnotherEnvironment() throws {
        let staging = Fx.syncedEnv("staging")
        let production = Fx.syncedEnv("production")
        let row = Fx.syncedItem("TOKEN", env: staging)
        let outcome = try ConfigItemEditPlanner(items: [row])
            .move(row.id, kind: .secret, scope: .environment(production.id), fingerprint: Self.value("v1"))
        #expect(Self.changes(outcome, environments: [staging, production]).sorted() == [
            "delete_secret env:staging TOKEN deleted",
            "set_secret env:production TOKEN new added",
        ])
    }

    // MARK: - Revert and Discard all

    @Test func revertOfAnUnsyncedRowRemovesIt() throws {
        let draft = Fx.item("DRAFT_KEY")
        let outcome = try ConfigItemEditPlanner(items: [draft]).revert(draft.id)
        #expect(outcome.items.isEmpty)
        #expect(outcome.mutations == [.remove(draft.id)])
    }

    @Test func revertRestoresNameDeletionAndForcePush() throws {
        var row = Fx.item("NEW_NAME", value: "v2", synced: "OLD_NAME", syncedValue: "v1", forcePush: true)
        row.isDeleted = false
        let outcome = try ConfigItemEditPlanner(items: [row]).revert(row.id)
        let reverted = try #require(outcome.items.first)
        #expect(reverted.name == "OLD_NAME")
        #expect(!reverted.forcePush)
        #expect(reverted.valueFingerprint == reverted.syncedFingerprint)
        #expect(Self.changes(outcome).isEmpty)
    }

    @Test func discardAllLeavesNothingPending() throws {
        let staging = Fx.syncedEnv("staging")
        let rows = [
            Fx.item("ADDED"),
            Fx.item("RENAMED", synced: "ORIGINAL", syncedValue: "v1"),
            Fx.item("ORIGINAL_TWO", synced: "ORIGINAL_TWO", syncedValue: "v1", deleted: true),
            Fx.item("EDITED", kind: .variable, env: staging, value: "b", synced: "EDITED", syncedValue: "a"),
            Fx.syncedItem("UNTOUCHED"),
        ]
        let outcome = try ConfigItemEditPlanner(items: rows).discardAll()
        #expect(Self.changes(outcome, environments: [staging]).isEmpty)
        #expect(outcome.items.count == 4)
    }

    // MARK: - Errors

    @Test func addingALiveNameIsRejected() {
        let row = Fx.syncedItem("API_TOKEN")
        #expect(throws: ItemEditError.nameTaken) {
            try ConfigItemEditPlanner(items: [row]).add(scope: .repository, kind: .secret, name: "api_token", fingerprint: Self.value("x"))
        }
    }

    @Test func renamingOntoALiveNameIsRejected() {
        let first = Fx.syncedItem("A_KEY")
        let second = Fx.syncedItem("B_KEY")
        #expect(throws: ItemEditError.nameTaken) {
            try ConfigItemEditPlanner(items: [first, second]).rename(first.id, to: "B_KEY", fingerprint: Self.value("x"))
        }
    }

    @Test func invalidNamesAreRejected() {
        #expect(throws: ItemEditError.invalidName(.invalidName(.reservedPrefix))) {
            try ConfigItemEditPlanner(items: []).add(scope: .repository, kind: .secret, name: "GITHUB_TOKEN", fingerprint: Self.value("x"))
        }
    }

    @Test func unknownRowsAreRejected() {
        #expect(throws: ItemEditError.itemNotFound) {
            try ConfigItemEditPlanner(items: []).delete(ConfigItemID())
        }
    }

    @Test func sameNameInAnotherKindIsAllowed() throws {
        let secret = Fx.syncedItem("SHARED")
        let outcome = try ConfigItemEditPlanner(items: [secret])
            .add(scope: .repository, kind: .variable, name: "SHARED", fingerprint: Self.value("x"))
        #expect(Self.changes(outcome) == ["set_variable repo SHARED new added"])
    }
}
