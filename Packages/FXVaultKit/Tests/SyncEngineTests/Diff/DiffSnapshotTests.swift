import Foundation
import Testing
import SyncEngine
import VaultCore

/// Snapshot helpers: environment name reservations (§7.1 editing rules) and the status column
/// staying consistent with the change table.
@Suite("SyncDiffTests.snapshot")
struct DiffSnapshotTests {
    @Test func environmentNameKeysReservePendingRenamesAndDeletes() throws {
        let renamed = Fx.env("stage", synced: "staging")
        let deleted = Fx.env("qa", synced: "QA", deleted: true)
        let plain = Fx.syncedEnv("Producción")
        let snapshot = Fx.snapshot(environments: [renamed, deleted, plain])

        let keys = snapshot.environmentNameKeys()
        #expect(keys.taken == ["stage", "qa", "producción"])
        #expect(keys.reserved == ["staging", "qa"])
        #expect(throws: ValidationError.self) {
            try EnvironmentNameValidator.checkAvailability(of: "STAGING", takenKeys: keys.taken, reservedKeys: keys.reserved)
        }
        #expect(throws: ValidationError.self) {
            try EnvironmentNameValidator.checkAvailability(of: "PRODUCCIÓN", takenKeys: keys.taken, reservedKeys: keys.reserved)
        }
        try EnvironmentNameValidator.checkAvailability(of: "preview", takenKeys: keys.taken, reservedKeys: keys.reserved)

        // Renaming `stage` back to its synced name is allowed: its own keys are excluded.
        let own = snapshot.environmentNameKeys(excluding: renamed.id)
        try EnvironmentNameValidator.checkAvailability(of: "staging", takenKeys: own.taken, reservedKeys: own.reserved)
        #expect(snapshot.environment(plain.id) == plain)
        #expect(snapshot.environment(EnvironmentID()) == nil)
    }

    @Test func itemsByScope() {
        let production = Fx.syncedEnv("production")
        let repoLevel = Fx.item("A")
        let scoped = Fx.item("B", env: production)
        let snapshot = Fx.snapshot(environments: [production], items: [repoLevel, scoped])
        #expect(snapshot.items(in: .repository) == [repoLevel])
        #expect(snapshot.items(in: .environment(production.id)) == [scoped])
    }

    /// The status column (`ConfigSyncStatus.derive`) agrees with the change table.
    @Test(arguments: [
        (Fx.syncedItem("SYNCED"), ConfigSyncStatus.synced),
        (Fx.item("ADDED"), .added),
        (Fx.item("ADDED_MISSING", value: nil), .blocked),
        (Fx.item("MODIFIED", value: "v2", synced: "MODIFIED", syncedValue: "v1"), .modified),
        (Fx.item("FORCED", synced: "FORCED", syncedValue: "v1", forcePush: true), .willPush),
        (Fx.item("FORCED_CHANGED", value: "v2", synced: "FORCED_CHANGED", syncedValue: "v1", forcePush: true), .modified),
        (Fx.item("FORCED_MISSING", value: nil, synced: "FORCED_MISSING", forcePush: true), .blocked),
        (Fx.item("NEW_NAME", synced: "OLD_NAME", syncedValue: "v1"), .added),
        (Fx.item("GONE", synced: "GONE", syncedValue: "v1", deleted: true), .deleted),
        (Fx.syncedItem("MISSING_ON_GITHUB_ONLY", value: nil), .synced),
    ])
    func statusMatchesTheChangeTable(row: ConfigItemSnapshotModel, status: ConfigSyncStatus) {
        #expect(ConfigSyncStatus.derive(row.syncFacts) == status)
        let changeSet = ChangeSetBuilder.build(Fx.snapshot(items: [row]))
        switch status {
        case .synced, .unverifiedShare:
            #expect(changeSet.isEmpty)
            #expect(!row.hasPendingChange)
        case .blocked:
            #expect(changeSet.changes.isEmpty)
            #expect(!changeSet.blocked.isEmpty)
        case .added, .modified, .deleted, .willPush:
            #expect(changeSet.blocked.isEmpty)
            #expect(!changeSet.changes.isEmpty)
            #expect(row.hasPendingChange)
        }
    }
}
