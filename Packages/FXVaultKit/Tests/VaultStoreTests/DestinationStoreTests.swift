import Foundation
import GRDB
import Testing
import VaultCore
@testable import VaultStore

/// §6 `v13_destinations` (v0.8.0): constraints of the four tables and ``DestinationStore``.
@Suite("Destination tables and store")
struct DestinationStoreTests {
    static let check = StoreError.constraintViolation(.check)
    static let unique = StoreError.constraintViolation(.unique)
    static let foreignKey = StoreError.constraintViolation(.foreignKey)
    static let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Constraints

    @Test func destinationsCheckProviderStageAndUniqueTarget() throws {
        let seeded = try SeededDatabase()
        let repo = seeded.repo.id.uuidString
        func insert(_ id: String = UUID().uuidString.lowercased(), provider: String = "azure_keyvault", key: String = "kv|a", stage: String = "NULL", stageKey: String = "NULL", repository: String? = nil) throws {
            try seeded.execute("""
                INSERT INTO destinations (id, repository_id, provider, target_key, settings_json, stage, stage_key, created_at, updated_at)
                VALUES ('\(id)', '\(repository ?? repo)', '\(provider)', '\(key)', '{}', \(stage), \(stageKey), 't', 't')
                """)
        }
        try insert()
        #expect(throws: Self.unique) { try insert(key: "kv|a") }
        try insert(key: "kv|b", stage: "'Production'", stageKey: "'production'")
        #expect(throws: Self.check) { try insert(provider: "aws", key: "x|1") }
        #expect(throws: Self.check) { try insert(key: "kv|c", stage: "'Production'") }
        #expect(throws: Self.check) { try insert("short", key: "kv|d") }
        #expect(throws: Self.foreignKey) { try insert(key: "kv|e", repository: UUID().uuidString.lowercased()) }
        try seeded.execute("DELETE FROM repositories")
        #expect(try seeded.integer("SELECT COUNT(*) FROM destinations") == 0)
    }

    @Test func destinationItemsCheckNamesValuesStateAndCascade() throws {
        let seeded = try SeededDatabase()
        let destination = UUID().uuidString.lowercased()
        try seeded.execute("""
            INSERT INTO destinations (id, repository_id, provider, target_key, settings_json, created_at, updated_at)
            VALUES ('\(destination)', '\(seeded.repo.id.uuidString)', 'azure_keyvault', 'kv|kv-sample', '{}', 't', 't')
            """)
        let blob = "x'" + String(repeating: "07", count: 40) + "'"
        func insertItem(
            _ name: String,
            kind: String = "secret",
            value: String? = nil,
            fingerprint: String? = nil,
            synced: String = "NULL",
            syncedKind: String = "NULL",
            deleted: Int = 0,
            destinationID: String? = nil
        ) throws {
            try seeded.execute("""
                INSERT INTO destination_items (id, destination_id, kind, name, value_ct, value_fp, synced_name, synced_kind, is_deleted, created_at, updated_at)
                VALUES ('\(UUID().uuidString.lowercased())', '\(destinationID ?? destination)', '\(kind)', '\(name)',
                  \(value ?? blob), \(fingerprint ?? blob), \(synced), \(syncedKind), \(deleted), 't', 't')
                """)
        }
        try insertItem("API_KEY")
        // One item per name, whatever its kind.
        #expect(throws: Self.unique) { try insertItem("API_KEY", kind: "variable") }
        #expect(throws: Self.check) { try insertItem("lower_name") }
        #expect(throws: Self.check) { try insertItem("BAD_KIND", kind: "token") }
        // A variable always has a value; value and fingerprint come together.
        #expect(throws: Self.check) { try insertItem("NO_VALUE_VAR", kind: "variable", value: "NULL", fingerprint: "NULL") }
        try insertItem("WRITE_ONLY", value: "NULL", fingerprint: "NULL", synced: "'WRITE_ONLY'", syncedKind: "'secret'")
        #expect(throws: Self.check) { try insertItem("HALF", value: "NULL") }
        // synced_name and synced_kind come together; a tombstone was synced.
        #expect(throws: Self.check) { try insertItem("HALF_SYNCED", synced: "'HALF_SYNCED'") }
        #expect(throws: Self.check) { try insertItem("NEVER_PUSHED_TOMBSTONE", deleted: 1) }
        #expect(throws: Self.foreignKey) { try insertItem("ORPHAN", destinationID: UUID().uuidString.lowercased()) }
        #expect(throws: Self.check) { try seeded.execute("UPDATE destination_items SET link_id = 'group-a'") }
        try seeded.execute("DELETE FROM destinations")
        #expect(try seeded.integer("SELECT COUNT(*) FROM destination_items") == 0)
    }

    @Test func journalChecksItsColumns() throws {
        let seeded = try SeededDatabase()
        let destination = UUID().uuidString.lowercased()
        try seeded.execute("""
            INSERT INTO destinations (id, repository_id, provider, target_key, settings_json, created_at, updated_at)
            VALUES ('\(destination)', '\(seeded.repo.id.uuidString)', 'azure_keyvault', 'kv|kv-sample', '{}', 't', 't')
            """)
        #expect(throws: Self.check) {
            try seeded.execute("""
                INSERT INTO destination_journal (run_id, destination_id, op, item_name, state, started_at)
                VALUES ('r', '\(destination)', 'purge', 'A', 'in_flight', 't')
                """)
        }
        try seeded.execute("""
            INSERT INTO destination_journal (run_id, destination_id, op, item_name, state, started_at)
            VALUES ('r', '\(destination)', 'set', 'A', 'in_flight', 't')
            """)
        try seeded.execute("DELETE FROM destinations")
        #expect(try seeded.text("SELECT destination_id FROM destination_journal") == nil)
    }

    // MARK: - Store

    @Test func settingsRoundTripKeyVaultTargets() throws {
        let targets: [DestinationTargetModel] = [
            .azureKeyVault(vaultName: "kv-sample-prod", tenantID: nil),
            .azureKeyVault(vaultName: "kv-sample-prod", tenantID: "contoso.onmicrosoft.com"),
        ]
        for target in targets {
            let record = DestinationRecord(repositoryID: RepoID(), target: target, stage: nil, sortOrder: 0, createdAt: Self.start, updatedAt: Self.start)
            #expect(try record.target() == target)
            #expect(record.targetKey == target.targetKey)
        }
        var tampered = DestinationRecord(repositoryID: RepoID(), target: targets[0], stage: nil, sortOrder: 0, createdAt: Self.start, updatedAt: Self.start)
        tampered.settingsJSON = #"{"version":2,"vaultName":"kv"}"#
        #expect(throws: StoreError.invalidStoredValue) { try tampered.target() }
        tampered.settingsJSON = #"{"version":1}"#
        #expect(throws: StoreError.invalidStoredValue) { try tampered.target() }
    }

    @Test func observedCountsFollowPendingState() throws {
        let seeded = try SeededDatabase()
        let store = DestinationStore(database: seeded.database)
        let destination = DestinationRecord(
            repositoryID: seeded.repo.id,
            target: .azureKeyVault(vaultName: "kv-sample-prod", tenantID: nil),
            stage: "production",
            sortOrder: 0,
            createdAt: Self.start,
            updatedAt: Self.start
        )
        let value = Data(repeating: 7, count: 40)
        let fingerprint = Data(repeating: 8, count: 32)
        let other = Data(repeating: 9, count: 32)
        try seeded.database.write { tx in
            try store.insertDestination(destination, in: tx)
            // A pending add, a synced item, a modified one, a write-only one and a tombstone.
            for (name, synced, syncedFP, hasValue, deleted) in [
                ("NEW_ONE", false, nil as Data?, true, false),
                ("SYNCED_ONE", true, fingerprint, true, false),
                ("MODIFIED_ONE", true, other, true, false),
                ("WRITE_ONLY", true, nil, false, false),
                ("GONE_ONE", true, fingerprint, true, true),
            ] {
                try store.insertItem(DestinationItemRecord(
                    destinationID: destination.id,
                    kind: .secret,
                    name: name,
                    valueCiphertext: hasValue ? value : nil,
                    valueFingerprint: hasValue ? fingerprint : nil,
                    isDeleted: deleted,
                    syncedName: synced ? name : nil,
                    syncedKind: synced ? .secret : nil,
                    syncedFingerprint: syncedFP,
                    createdAt: Self.start,
                    updatedAt: Self.start
                ), in: tx)
            }
        }
        let model = try #require(try store.fetchDestinations(repositoryID: seeded.repo.id).first)
        #expect(model.secretCount == 4)
        #expect(model.pendingCount == 3)
        #expect(model.valueMissingCount == 1)
        #expect(try store.fetchPendingCounts() == [seeded.repo.id: 3])
        let statuses = Dictionary(uniqueKeysWithValues: try store.fetchItems(destinationID: destination.id).map { ($0.name, $0.syncStatus) })
        #expect(statuses == [
            "NEW_ONE": .added, "SYNCED_ONE": .synced, "MODIFIED_ONE": .modified, "WRITE_ONLY": .synced, "GONE_ONE": .deleted,
        ])
        let operations = try seeded.database.read { tx in
            try store.fetchItemStates(destinationIDs: [destination.id], in: tx).map { [$0.name: $0.pendingOperation] }
        }
        #expect(operations.contains(["NEW_ONE": .add]))
        #expect(operations.contains(["MODIFIED_ONE": .update]))
        #expect(operations.contains(["GONE_ONE": .delete]))
        #expect(operations.contains(["WRITE_ONLY": nil]))
    }

    @Test func journalPruningKeepsInFlightRows() throws {
        let seeded = try SeededDatabase()
        let store = DestinationStore(database: seeded.database)
        let old = Self.start
        let now = old + Timeouts.syncJournalRetention.timeInterval + 1
        try seeded.database.write { tx in
            _ = try store.appendJournal(DestinationJournalRecord(runID: SyncRunID(), destinationID: nil, itemID: nil, operation: .set, itemName: "A", state: .succeeded, startedAt: old), in: tx)
            _ = try store.appendJournal(DestinationJournalRecord(runID: SyncRunID(), destinationID: nil, itemID: nil, operation: .set, itemName: "B", state: .inFlight, startedAt: old), in: tx)
            #expect(try store.pruneJournal(now: now, in: tx) == 1)
        }
        #expect(try seeded.integer("SELECT COUNT(*) FROM destination_journal") == 1)
    }
}
