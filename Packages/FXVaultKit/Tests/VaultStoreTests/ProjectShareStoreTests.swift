import Foundation
import GRDB
import Testing
import VaultCore
@testable import VaultStore

/// §6 `v14_project_shares` (v0.9.0): constraints of `sent_shares` and `share_hold`, and the
/// stores over them. (v15 drops `teammates`; ``MigrationTests`` covers that.)
@Suite("Project share tables and stores")
struct ProjectShareStoreTests {
    static let check = StoreError.constraintViolation(.check)
    static let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Constraints

    @Test func sentSharesCheckModeIdsAndExpiry() throws {
        let seeded = try SeededDatabase()
        func insert(
            id: String = UUID().uuidString.lowercased(),
            package: String = UUID().uuidString.lowercased(),
            created: String = "2026-10-17T09:00:00.000Z",
            expires: String = "2026-10-24T09:00:00.000Z",
            mode: String = "passphrase"
        ) throws {
            try seeded.execute("""
                INSERT INTO sent_shares (id, package_id, created_at, expires_at, mode, recipients, summary)
                VALUES ('\(id)', '\(package)', '\(created)', '\(expires)', '\(mode)', '[]', '{}')
                """)
        }
        try insert()
        try insert(mode: "teammates")
        #expect(throws: Self.check) { try insert(mode: "link") }
        #expect(throws: Self.check) { try insert(id: "short") }
        #expect(throws: Self.check) { try insert(package: "short") }
        #expect(throws: Self.check) { try insert(expires: "2026-10-17T09:00:00.000Z") }
        #expect(throws: Self.check) { try insert(expires: "2026-10-16T09:00:00.000Z") }
    }

    @Test func shareHoldIsALowercaseUUIDOrNull() throws {
        let seeded = try SeededDatabase()
        let item = Sample.item(repositoryID: seeded.repo.id)
        try seeded.config.insertItem(item)
        let id = item.id.uuidString
        #expect(try seeded.text("SELECT share_hold FROM config_items WHERE id = '\(id)'") == nil)
        let package = UUID().uuidString.lowercased()
        try seeded.execute("UPDATE config_items SET share_hold = '\(package)' WHERE id = '\(id)'")
        #expect(throws: Self.check) {
            try seeded.execute("UPDATE config_items SET share_hold = '\(package.uppercased())' WHERE id = '\(id)'")
        }
        #expect(throws: Self.check) {
            try seeded.execute("UPDATE config_items SET share_hold = 'pkg-a' WHERE id = '\(id)'")
        }
        try seeded.execute("UPDATE config_items SET share_hold = NULL WHERE id = '\(id)'")

        let destination = try Self.insertDestination(seeded)
        let destinationItem = UUID().uuidString.lowercased()
        try seeded.execute("""
            INSERT INTO destination_items (id, destination_id, kind, name, created_at, updated_at)
            VALUES ('\(destinationItem)', '\(destination.uuidString)', 'secret', 'API_KEY', 't', 't')
            """)
        try seeded.execute("UPDATE destination_items SET share_hold = '\(package)' WHERE id = '\(destinationItem)'")
        #expect(throws: Self.check) {
            try seeded.execute("UPDATE destination_items SET share_hold = 'pkg-a' WHERE id = '\(destinationItem)'")
        }
        try seeded.execute("UPDATE destination_items SET share_hold = NULL WHERE id = '\(destinationItem)'")
    }

    // MARK: - SentShareStore

    @Test func sentSharesListNewestFirstAndDelete() throws {
        let seeded = try SeededDatabase()
        let store = SentShareStore(database: seeded.database)
        let summary = SentShareSummaryModel(stages: ["staging"], places: [
            SentSharePlaceModel(kind: .environment, repository: "owner-a/example-web", name: "staging", secretNames: ["API_KEY"], variableNames: ["API_URL"]),
            SentSharePlaceModel(kind: .destination, repository: "owner-a/example-web", name: "kv-example-staging", secretNames: ["DB_URL"], variableNames: []),
        ])
        let older = SentShareModel(
            packageID: SharePackageID(),
            createdAt: Self.start,
            expiresAt: ShareExpiryChoice.sevenDays.expiry(from: Self.start),
            mode: .passphrase,
            recipientIDs: [],
            summary: summary
        )
        let newer = SentShareModel(
            packageID: SharePackageID(),
            createdAt: Self.start.addingTimeInterval(60),
            expiresAt: ShareExpiryChoice.oneDay.expiry(from: Self.start.addingTimeInterval(60)),
            mode: .teammates,
            recipientIDs: [String(repeating: "ab", count: 16), String(repeating: "cd", count: 16)],
            summary: SentShareSummaryModel(stages: [], places: [])
        )
        try store.insert(older)
        try seeded.database.write { tx in try store.insert(newer, in: tx) }

        let listed = try store.fetchAll()
        #expect(listed == [newer, older])
        #expect(listed.last?.summary.secretCount == 2)
        #expect(try store.fetch(id: older.id) == older)
        #expect(try seeded.text("SELECT recipients FROM sent_shares WHERE id = '\(newer.id.uuidString)'")
            == #"["\#(String(repeating: "ab", count: 16))","\#(String(repeating: "cd", count: 16))"]"#)
        #expect(try store.delete(id: older.id))
        #expect(try !store.delete(id: older.id))
        #expect(try store.fetchAll() == [newer])
    }

    @Test func sentSharesObservationSeesInserts() async throws {
        let seeded = try SeededDatabase()
        let store = SentShareStore(database: seeded.database)
        var iterator = store.observe().makeAsyncIterator()
        #expect(try await iterator.next() == [])
        let share = SentShareModel(
            packageID: SharePackageID(),
            createdAt: Self.start,
            expiresAt: ShareExpiryChoice.thirtyDays.expiry(from: Self.start),
            mode: .passphrase,
            recipientIDs: [],
            summary: SentShareSummaryModel()
        )
        try store.insert(share)
        #expect(try await iterator.next() == [share])
    }

    // MARK: - Holds

    @Test func configHoldsAreSetQueriedAndClearedWithoutTouchingValues() throws {
        let seeded = try SeededDatabase()
        let first = Sample.item(repositoryID: seeded.repo.id, name: "API_KEY")
        let second = Sample.item(repositoryID: seeded.repo.id, name: "API_URL")
        let free = Sample.item(repositoryID: seeded.repo.id, name: "FREE")
        for item in [first, second, free] {
            try seeded.config.insertItem(item)
        }
        let package = SharePackageID()
        let other = SharePackageID()
        try seeded.database.write { tx in
            try seeded.config.setShareHold(package, itemIDs: [first.id, second.id], in: tx)
            try seeded.config.setShareHold(other, itemIDs: [free.id], in: tx)
            try seeded.config.setShareHold(nil, itemIDs: [], in: tx)
        }
        #expect(try seeded.config.fetchHeldItemStates().count == 3)
        let held = try seeded.config.fetchHeldItemStates(packageID: package)
        #expect(held.map(\.name) == ["API_KEY", "API_URL"])
        #expect(held.allSatisfy { $0.shareHold == package })
        #expect(try seeded.config.fetchItemRecord(id: first.id)?.valueCiphertext == first.valueCiphertext)
        #expect(try seeded.config.fetchItemRecord(id: first.id)?.shareHold == package)

        let released = try seeded.database.write { tx in try seeded.config.clearShareHold(packageID: package, in: tx) }
        #expect(released == 2)
        #expect(try seeded.config.fetchHeldItemStates().map(\.name) == ["FREE"])
        try seeded.database.write { tx in try seeded.config.setShareHold(nil, itemIDs: [free.id], in: tx) }
        #expect(try seeded.config.fetchHeldItemStates().isEmpty)
    }

    @Test func destinationHoldsAreSetQueriedAndCleared() throws {
        let seeded = try SeededDatabase()
        let destinationID = try Self.insertDestination(seeded)
        let store = DestinationStore(database: seeded.database)
        let items = ["DB_URL", "API_KEY"].map { name in
            DestinationItemRecord(
                destinationID: destinationID,
                kind: .secret,
                name: name,
                valueCiphertext: Data(repeating: 7, count: 40),
                valueFingerprint: Data(repeating: 8, count: 32),
                createdAt: Self.start,
                updatedAt: Self.start
            )
        }
        let package = SharePackageID()
        try seeded.database.write { tx in
            for item in items {
                try store.insertItem(item, in: tx)
            }
            try store.setShareHold(package, itemIDs: [items[0].id], in: tx)
        }
        let held = try store.fetchHeldItemStates(packageID: package)
        #expect(held.map(\.name) == ["DB_URL"])
        #expect(held.first?.shareHold == package)
        #expect(try store.fetchHeldItemStates(packageID: SharePackageID()).isEmpty)
        #expect(try store.fetchItemRecord(id: items[0].id)?.state.shareHold == package)
        #expect(try store.fetchItemRecord(id: items[1].id)?.shareHold == nil)
        let released = try seeded.database.write { tx in try store.clearShareHold(packageID: package, in: tx) }
        #expect(released == 1)
        #expect(try store.fetchHeldItemStates().isEmpty)
    }

    // MARK: - Helpers

    static func insertDestination(_ seeded: SeededDatabase) throws -> DestinationID {
        let id = DestinationID()
        try seeded.execute("""
            INSERT INTO destinations (id, repository_id, provider, target_key, settings_json, created_at, updated_at)
            VALUES ('\(id.uuidString)', '\(seeded.repo.id.uuidString)', 'vercel', 'vc|-|prj_sample|preview', '{}', 't', 't')
            """)
        return id
    }
}
