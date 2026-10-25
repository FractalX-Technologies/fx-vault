import Foundation
import GRDB
import Testing
import VaultCore
@testable import VaultStore

/// §6 `v17_organizations` (1.0): constraints of `organizations` and `org_items` and
/// ``OrganizationStore``.
@Suite("Organization tables and store")
struct OrganizationStoreTests {
    static let check = StoreError.constraintViolation(.check)
    static let unique = StoreError.constraintViolation(.unique)
    static let foreignKey = StoreError.constraintViolation(.foreignKey)
    static let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Constraints

    @Test func organizationsCheckTheLoginAndItsKey() throws {
        let seeded = try SeededDatabase()
        func insert(login: String, key: String) throws {
            try seeded.execute("""
                INSERT INTO organizations (id, login, login_key, account_login, created_at, updated_at)
                VALUES ('\(UUID().uuidString.lowercased())', '\(login)', '\(key)', 'user-a', 't', 't')
                """)
        }
        try insert(login: "Example-Org", key: "example-org")
        #expect(throws: Self.unique) { try insert(login: "example-org", key: "example-org") }
        #expect(throws: Self.check) { try insert(login: "Other", key: "Other") }
        #expect(throws: Self.check) { try insert(login: String(repeating: "a", count: 40), key: String(repeating: "a", count: 40)) }
    }

    @Test func orgItemsCheckNamesValuesVisibilityAndCascade() throws {
        let seeded = try SeededDatabase()
        let organization = UUID().uuidString.lowercased()
        try seeded.execute("""
            INSERT INTO organizations (id, login, login_key, account_login, created_at, updated_at)
            VALUES ('\(organization)', 'example-org', 'example-org', 'user-a', 't', 't')
            """)
        let blob = "x'" + String(repeating: "07", count: 40) + "'"
        func insertItem(
            _ name: String,
            kind: String = "variable",
            value: String? = nil,
            fingerprint: String? = nil,
            visibility: String = "all",
            selected: String = "NULL",
            organizationID: String? = nil
        ) throws {
            try seeded.execute("""
                INSERT INTO org_items (id, organization_id, kind, name, value_ct, value_fp, visibility, selected_count, created_at, updated_at)
                VALUES ('\(UUID().uuidString.lowercased())', '\(organizationID ?? organization)', '\(kind)', '\(name)',
                  \(value ?? blob), \(fingerprint ?? blob), '\(visibility)', \(selected), 't', 't')
                """)
        }
        try insertItem("REGION")
        // One name per kind: a secret and a variable may share it.
        #expect(throws: Self.unique) { try insertItem("REGION") }
        try insertItem("REGION", kind: "secret", value: "NULL", fingerprint: "NULL")
        #expect(throws: Self.check) { try insertItem("lower_name") }
        #expect(throws: Self.check) { try insertItem("BAD_KIND", kind: "token") }
        #expect(throws: Self.check) { try insertItem("BAD_VISIBILITY", visibility: "internal") }
        #expect(throws: Self.check) { try insertItem("NEGATIVE", visibility: "selected", selected: "-1") }
        // A variable always has a value; value and fingerprint come together.
        #expect(throws: Self.check) { try insertItem("NO_VALUE_VAR", value: "NULL", fingerprint: "NULL") }
        #expect(throws: Self.check) { try insertItem("HALF", kind: "secret", value: "NULL") }
        #expect(throws: Self.foreignKey) { try insertItem("ORPHAN", organizationID: UUID().uuidString.lowercased()) }
        try seeded.execute("DELETE FROM organizations")
        #expect(try seeded.integer("SELECT COUNT(*) FROM org_items") == 0)
    }

    // MARK: - Store

    @Test func storeFindsByLoginCountsItemsAndRemovesThem() throws {
        let seeded = try SeededDatabase()
        let store = OrganizationStore(database: seeded.database)
        let organization = OrganizationRecord(login: "Example-Org", accountLogin: "user-a", createdAt: Self.start, updatedAt: Self.start)
        let other = OrganizationRecord(login: "another-org", accountLogin: "user-a", createdAt: Self.start, updatedAt: Self.start)
        let blob = Data(repeating: 7, count: 40)
        try seeded.database.write { tx in
            try store.insertOrganization(organization, in: tx)
            try store.insertOrganization(other, in: tx)
            for name in ["NPM_TOKEN", "SONAR_TOKEN"] {
                try store.insertItem(OrgItemRecord(
                    organizationID: organization.id, kind: .secret, name: name, visibility: .private, createdAt: Self.start, updatedAt: Self.start
                ), in: tx)
            }
            try store.insertItem(OrgItemRecord(
                organizationID: organization.id, kind: .variable, name: "REGION", valueCiphertext: blob, valueFingerprint: blob,
                visibility: .selected, selectedCount: 2, createdAt: Self.start, updatedAt: Self.start
            ), in: tx)
        }
        #expect(throws: Self.unique) {
            try seeded.database.write { tx in
                try store.insertOrganization(
                    OrganizationRecord(login: "EXAMPLE-ORG", accountLogin: "user-a", createdAt: Self.start, updatedAt: Self.start),
                    in: tx
                )
            }
        }

        #expect(try store.fetchOrganization(login: "example-ORG")?.id == organization.id)
        let models = try store.fetchOrganizations()
        #expect(models.map(\.login) == ["another-org", "Example-Org"])
        #expect(models.last?.secretCount == 2)
        #expect(models.last?.variableCount == 1)
        #expect(models.first?.secretCount == 0)

        let items = try store.fetchItems(organizationID: organization.id)
        #expect(items.map(\.name) == ["NPM_TOKEN", "REGION", "SONAR_TOKEN"])
        let region = try #require(items.first { $0.name == "REGION" })
        #expect(region.hasValue)
        #expect(region.selectedRepositoryCount == 2)
        #expect(items.first?.hasValue == false)
        #expect(items.first?.selectedRepositoryCount == nil)

        #expect(try store.deleteOrganization(id: organization.id))
        #expect(try store.deleteOrganization(id: organization.id) == false)
        #expect(try store.fetchItems(organizationID: organization.id).isEmpty)
        #expect(try store.fetchOrganizations().map(\.login) == ["another-org"])
    }

    @Test func updatingAMissingItemThrowsNotFound() throws {
        let seeded = try SeededDatabase()
        let store = OrganizationStore(database: seeded.database)
        let item = OrgItemRecord(
            organizationID: OrganizationID(), kind: .secret, name: "GONE", visibility: .all, createdAt: Self.start, updatedAt: Self.start
        )
        #expect(throws: StoreError.notFound) {
            try seeded.database.write { tx in try store.updateItem(item, in: tx) }
        }
    }
}
