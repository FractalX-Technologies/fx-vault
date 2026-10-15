import Foundation
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

@Suite("VaultSession")
struct VaultSessionTests {
    @Test func entryPointsThrowLockedWhileLocked() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        harness.manager.lock()
        #expect(throws: VaultError.locked) {
            try harness.session.write { _, _ in }
        }
        #expect(throws: VaultError.locked) {
            try harness.session.read { _, _ in }
        }
        #expect(harness.session.context == nil)
    }

    @Test func writeRollsBackWhenTheVaultLocksDuringTheBody() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        let repo = try harness.seedRepository()
        let id = try harness.insertItem(repo: repo, name: "API_TOKEN", value: VaultFixture.secretValue)
        let before = try harness.itemRecord(id)

        #expect(throws: VaultError.locked) {
            try harness.session.write { keys, tx in
                var record = before
                let replacement = SecretBytes(utf8: VaultFixture.variableValue)
                defer { replacement.wipe() }
                record.valueCiphertext = try keys.seal(replacement, for: VaultHarness.valueAAD(record))
                record.valueFingerprint = keys.fingerprint(replacement, rowID: id)
                try ConfigStore(database: harness.database).updateItem(record, in: tx)
                harness.manager.lock()
            }
        }
        #expect(try harness.itemRecord(id) == before)
    }

    @Test func generationChangesOnLockAndUnlock() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        let generation = harness.session.generation
        try harness.session.ensureCurrent(generation)
        harness.manager.lock()
        #expect(throws: VaultError.locked) {
            try harness.session.ensureCurrent(generation)
        }
        try await harness.manager.unlock(password: VaultFixture.password)
        #expect(harness.session.generation != generation)
        #expect(throws: VaultError.locked) {
            try harness.session.ensureCurrent(generation)
        }
        try harness.session.ensureCurrent(harness.session.generation)
    }

    @Test func rotationInvalidatesEarlierGenerations() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        let generation = harness.session.generation
        let rotated = try await harness.manager.rotateDEK(password: VaultFixture.password)
        rotated.wipe()
        #expect(throws: VaultError.locked) {
            try harness.session.ensureCurrent(generation)
        }
        let context = try #require(harness.session.context)
        #expect(context.dekVersion == UnlockedKeys.initialDEKVersion + 1)
    }

    @Test func readFallsBackToTheWriterWhenKeysAndSnapshotDisagree() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        // Simulate a committing rotation: the row says another DEK version than the keys.
        var vault = try harness.vaultRecord()
        vault.dekVersion += 1
        try harness.records.updateVault(vault)
        #expect(throws: VaultError.locked) {
            try harness.session.read { _, _ in }
        }
        #expect(throws: VaultError.locked) {
            try harness.session.write { _, _ in }
        }
    }

    @Test func concurrentReadersAndWritersSurviveARotation() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        let repo = try harness.seedRepository()
        let ids = try (0..<Self.concurrentItems).map { index in
            try harness.insertItem(repo: repo, name: "ITEM_\(index)", value: VaultFixture.secretValue)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let rotated = try await harness.manager.rotateDEK(password: VaultFixture.password)
                rotated.wipe()
            }
            for id in ids {
                group.addTask {
                    let value = try harness.value(of: id)
                    #expect(value == VaultFixture.secretValue)
                }
            }
            for index in 0..<Self.concurrentItems {
                group.addTask {
                    try harness.insertItem(repo: repo, name: "LATE_\(index)", value: VaultFixture.variableValue)
                }
            }
            try await group.waitForAll()
        }

        for record in try ConfigStore(database: harness.database).fetchItemRecords(repositoryID: repo.id) {
            #expect(try harness.value(of: record.id) != nil)
        }
    }

    private static let concurrentItems = 8
}
