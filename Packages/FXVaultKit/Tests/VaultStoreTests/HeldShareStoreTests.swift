import Foundation
import GRDB
import Testing
import VaultCore
@testable import VaultStore

/// `ShareHoldStore` (v0.9.0): the From Files inputs across both item tables, releasing holds,
/// and the verified sender of an imported share file.
@Suite("Held share store")
struct HeldShareStoreTests {
    @Test func senderDeviceIDIsLowercaseHexOrNull() throws {
        let seeded = try SeededDatabase()
        let package = SharePackageID()
        let device = String(repeating: "ab", count: 16)
        try seeded.shares.recordImport(ImportedSharePackageRecord(
            packageID: package,
            createdAt: Sample.start,
            importedAt: Sample.start,
            senderName: "Teammate",
            senderDeviceID: device
        ))
        #expect(try seeded.shares.fetch(package)?.senderDeviceID == device)
        let id = package.uuidString
        #expect(throws: ProjectShareStoreTests.check) {
            try seeded.execute("UPDATE imported_share_packages SET sender_device_id = '\(device.uppercased())' WHERE package_id = '\(id)'")
        }
        #expect(throws: ProjectShareStoreTests.check) {
            try seeded.execute("UPDATE imported_share_packages SET sender_device_id = 'abcd' WHERE package_id = '\(id)'")
        }
        try seeded.execute("UPDATE imported_share_packages SET sender_device_id = NULL WHERE package_id = '\(id)'")
    }

    @Test func inputsCoverBothTablesAndReleasesClearThem() throws {
        let seeded = try SeededDatabase()
        let store = ShareHoldStore(database: seeded.database)
        #expect(try store.fetchInputs().isEmpty)

        let item = Sample.item(repositoryID: seeded.repo.id)
        try seeded.config.insertItem(item)
        let record = DestinationRecord(
            repositoryID: seeded.repo.id,
            target: .vercel(projectID: "prj_sample", projectName: "example-web", teamID: nil, environment: .preview),
            stage: "staging",
            connectionID: nil,
            sortOrder: 0,
            createdAt: Sample.start,
            updatedAt: Sample.start
        )
        try seeded.database.write { tx in try DestinationStore(database: seeded.database).insertDestination(record, in: tx) }
        let destination = record.id
        let destinationItem = ConfigItemID()
        try seeded.execute("""
            INSERT INTO destination_items (id, destination_id, kind, name, created_at, updated_at)
            VALUES ('\(destinationItem.uuidString)', '\(destination.uuidString)', 'secret', 'API_KEY', 't', 't')
            """)
        let package = SharePackageID()
        try seeded.database.write { tx in
            try seeded.config.setShareHold(package, itemIDs: [item.id], in: tx)
            try DestinationStore(database: seeded.database).setShareHold(package, itemIDs: [destinationItem], in: tx)
            try seeded.shares.recordImport(ImportedSharePackageRecord(
                packageID: package,
                createdAt: Sample.start,
                importedAt: Sample.start,
                senderName: "Teammate"
            ), in: tx)
        }

        let inputs = try store.fetchInputs()
        #expect(!inputs.isEmpty)
        #expect(inputs.packages.map(\.packageID) == [package])
        #expect(inputs.repositories.map(\.repository.id) == [seeded.repo.id])
        #expect(inputs.repositories.first?.items.first { $0.id == item.id }?.shareHold == package)
        #expect(inputs.destinationItems.map(\.id) == [destinationItem])
        #expect(inputs.destinations.map(\.id) == [destination])

        #expect(try seeded.database.write { tx in try store.clearShareHold(itemIDs: [destinationItem], in: tx) } == 1)
        #expect(try store.fetchInputs().destinationItems.isEmpty)
        #expect(try seeded.database.write { tx in try store.clearShareHold(packageIDs: [package], in: tx) } == 1)
        #expect(try store.fetchInputs().isEmpty)
    }
}
