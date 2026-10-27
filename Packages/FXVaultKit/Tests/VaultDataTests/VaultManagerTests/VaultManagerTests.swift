import Foundation
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

@Suite("VaultManager lifecycle")
struct VaultManagerTests {
    // MARK: - Create

    @Test func fixturePasswordsMeetThePolicy() {
        for password in [VaultFixture.password, VaultFixture.otherPassword, VaultFixture.thirdPassword] {
            #expect(PasswordStrength.evaluate(password).isAcceptable)
        }
        #expect(!PasswordStrength.evaluate(VaultFixture.weakPassword).isAcceptable)
    }

    @Test func freshDatabaseHasNoVault() throws {
        let harness = try VaultHarness()
        #expect(harness.manager.state == .noVault)
        #expect(harness.session.isLocked)
        #expect(harness.session.context == nil)
    }

    @Test func createLeavesTheVaultUnlockedWithBothWraps() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }

        #expect(harness.manager.state == .unlocked)
        let vault = try harness.vaultRecord()
        #expect(vault.dekVersion == Int(UnlockedKeys.initialDEKVersion))
        #expect(vault.lastPasswordUnlockAt == harness.clock.now)
        #expect(vault.lastPasswordBootSession == FakeBuildCapabilities.defaultBootSession)
        #expect(vault.biometryStateHash == nil)
        let wraps = try harness.records.fetchKeyWraps()
        #expect(wraps.map(\.method) == [.password, .recovery])
        #expect(harness.session.context == (try vault.keyContext()))
        #expect(recoveryKey.groups.count == Limits.recoveryKeyGroupCount)
    }

    @Test func createTwiceIsRejected() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        let error = await vaultError {
            _ = try await harness.manager.create(password: VaultFixture.otherPassword)
        }
        #expect(error == .alreadyInitialized)
    }

    @Test func weakPasswordIsRejectedBeforeAnythingIsWritten() async throws {
        let harness = try VaultHarness()
        await #expect(throws: PasswordPolicyError.self) {
            _ = try await harness.manager.create(password: VaultFixture.weakPassword)
        }
        #expect(harness.manager.state == .noVault)
        #expect(try harness.records.fetchVault() == nil)
    }

    // MARK: - Unlock and lock

    @Test func lockDropsKeysRunsHooksAndUnlockRestoresThem() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        let repo = try harness.seedRepository()
        let id = try harness.insertItem(repo: repo, name: "API_TOKEN", value: VaultFixture.secretValue)

        harness.manager.lock()
        #expect(harness.manager.state == .locked)
        #expect(harness.session.isLocked)
        #expect(harness.lockHook.value == 1)
        #expect(harness.biometrics.invalidateCount == 1)
        #expect(throws: VaultError.locked) {
            try harness.session.withKeys { _ in }
        }
        #expect(throws: VaultError.locked) {
            _ = try harness.value(of: id)
        }

        try await harness.manager.unlock(password: VaultFixture.password)
        #expect(harness.manager.state == .unlocked)
        #expect(try harness.value(of: id) == VaultFixture.secretValue)
    }

    @Test func wrongPasswordKeepsTheVaultLocked() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        harness.manager.lock()
        let error = await vaultError {
            try await harness.manager.unlock(password: VaultFixture.otherPassword)
        }
        #expect(error == .wrongPassword)
        #expect(harness.manager.state == .locked)
    }

    @Test func unlockWithoutVaultIsNotInitialized() async throws {
        let harness = try VaultHarness()
        let error = await vaultError {
            try await harness.manager.unlock(password: VaultFixture.password)
        }
        #expect(error == .notInitialized)
    }

    @Test func passwordUnlockRecordsTimeAndBootSession() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        harness.manager.lock()
        harness.clock.advance(by: .seconds(Timeouts.secondsPerHour))
        harness.capabilities.bootSession = "boot-b"
        try await harness.manager.unlock(password: VaultFixture.password)
        let vault = try harness.vaultRecord()
        #expect(vault.lastPasswordUnlockAt == harness.clock.now)
        #expect(vault.lastPasswordBootSession == "boot-b")
    }

    @Test func keyCheckMismatchIsCorrupted() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        harness.manager.lock()
        var vault = try harness.vaultRecord()
        vault.kcv = Data(repeating: 0xA5, count: Limits.kcvBytes)
        try harness.records.updateVault(vault)

        let error = await vaultError {
            try await harness.manager.unlock(password: VaultFixture.password)
        }
        #expect(error == .corrupted(.keyCheckMismatch))
        #expect(harness.manager.state == .locked)
    }

    @Test func missingPasswordWrapIsCorrupted() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        harness.manager.lock()
        try harness.records.deleteKeyWrap(.password)
        let error = await vaultError {
            try await harness.manager.unlock(password: VaultFixture.password)
        }
        #expect(error == .corrupted(.missingKeyWrap))
    }

    @Test func managerReadsAnExistingVaultAsLocked() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        let reopened = try VaultManager(
            session: VaultSession(database: harness.database),
            policy: .testing,
            biometricStore: FakeBiometricKeyStore(),
            capabilities: FakeBuildCapabilities()
        )
        #expect(reopened.state == .locked)
    }

    // MARK: - Change password

    @Test func changePasswordWithoutRotationKeepsTheDEK() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        let repo = try harness.seedRepository()
        let id = try harness.insertItem(repo: repo, name: "API_TOKEN", value: VaultFixture.secretValue)
        let before = try harness.vaultRecord()

        let newRecovery = try await harness.manager.changePassword(
            current: VaultFixture.password,
            new: VaultFixture.otherPassword,
            rotate: false
        )
        #expect(newRecovery == nil)
        let after = try harness.vaultRecord()
        #expect(after.dekVersion == before.dekVersion)
        #expect(after.kcv == before.kcv)

        harness.manager.lock()
        let error = await vaultError {
            try await harness.manager.unlock(password: VaultFixture.password)
        }
        #expect(error == .wrongPassword)
        try await harness.manager.unlock(password: VaultFixture.otherPassword)
        #expect(try harness.value(of: id) == VaultFixture.secretValue)

        // The recovery key is unchanged without rotation.
        let wrap = try #require(try harness.records.fetchKeyWrap(.recovery)).model()
        _ = try KeyWrap.unwrap(wrap, recoveryKey: recoveryKey, context: after.keyContext())
    }

    @Test func changePasswordRequiresTheCurrentPassword() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        let error = await vaultError {
            _ = try await harness.manager.changePassword(
                current: VaultFixture.thirdPassword,
                new: VaultFixture.otherPassword,
                rotate: false
            )
        }
        #expect(error == .wrongPassword)
    }

    @Test func changePasswordRequiresAnUnlockedVault() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        harness.manager.lock()
        let error = await vaultError {
            _ = try await harness.manager.changePassword(
                current: VaultFixture.password,
                new: VaultFixture.otherPassword,
                rotate: true
            )
        }
        #expect(error == .locked)
    }

    @Test func changePasswordWithRotationIssuesANewRecoveryKey() async throws {
        let (harness, oldRecovery) = try await VaultHarness.created()
        defer { oldRecovery.wipe() }
        let repo = try harness.seedRepository()
        let id = try harness.insertItem(repo: repo, name: "API_TOKEN", value: VaultFixture.secretValue)
        let before = try harness.vaultRecord()

        let newRecovery = try #require(
            try await harness.manager.changePassword(
                current: VaultFixture.password,
                new: VaultFixture.otherPassword,
                rotate: true
            )
        )
        defer { newRecovery.wipe() }

        let after = try harness.vaultRecord()
        #expect(after.dekVersion == before.dekVersion + 1)
        #expect(after.kcv != before.kcv)
        #expect(try harness.value(of: id) == VaultFixture.secretValue)

        let recoveryWrap = try #require(try harness.records.fetchKeyWrap(.recovery)).model()
        #expect(throws: VaultError.invalidRecoveryKey) {
            _ = try KeyWrap.unwrap(recoveryWrap, recoveryKey: oldRecovery, context: after.keyContext())
        }
        _ = try KeyWrap.unwrap(recoveryWrap, recoveryKey: newRecovery, context: after.keyContext())

        harness.manager.lock()
        try await harness.manager.unlock(password: VaultFixture.otherPassword)
        #expect(try harness.value(of: id) == VaultFixture.secretValue)
    }

    // MARK: - Recovery reset

    @Test func recoveryResetAlwaysRotatesAndReplacesCredentials() async throws {
        let (harness, oldRecovery) = try await VaultHarness.created()
        defer { oldRecovery.wipe() }
        let repo = try harness.seedRepository()
        let id = try harness.insertItem(repo: repo, name: "API_TOKEN", value: VaultFixture.secretValue)
        let before = try harness.vaultRecord()
        harness.manager.lock()

        let newRecovery = try await harness.manager.resetWithRecoveryKey(
            oldRecovery,
            newPassword: VaultFixture.otherPassword
        )
        defer { newRecovery.wipe() }

        #expect(harness.manager.state == .unlocked)
        let after = try harness.vaultRecord()
        #expect(after.dekVersion == before.dekVersion + 1)
        #expect(try harness.value(of: id) == VaultFixture.secretValue)

        harness.manager.lock()
        let oldKeyError = await vaultError {
            _ = try await harness.manager.resetWithRecoveryKey(oldRecovery, newPassword: VaultFixture.thirdPassword)
        }
        #expect(oldKeyError == .invalidRecoveryKey)
        let oldPasswordError = await vaultError {
            try await harness.manager.unlock(password: VaultFixture.password)
        }
        #expect(oldPasswordError == .wrongPassword)
        try await harness.manager.unlock(password: VaultFixture.otherPassword)

        harness.manager.lock()
        let third = try await harness.manager.resetWithRecoveryKey(newRecovery, newPassword: VaultFixture.thirdPassword)
        third.wipe()
        #expect(try harness.value(of: id) == VaultFixture.secretValue)
    }

    @Test func recoveryKeyParsingRejectsTypos() async throws {
        let (_, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        var text = Array(recoveryKey.text)
        text[0] = text[0] == "A" ? "B" : "A"
        #expect(throws: VaultError.invalidRecoveryKey) {
            _ = try RecoveryKey(parsing: String(text))
        }
    }

    // MARK: - Rotation

    @Test func rotateDEKReencryptsValuesSyncedValuesAndFingerprints() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        let repo = try harness.seedRepository()
        let secret = try harness.insertItem(
            repo: repo,
            name: "API_TOKEN",
            value: VaultFixture.secretValue,
            syncedValue: VaultFixture.syncedSecretValue
        )
        let variable = try harness.insertItem(
            repo: repo,
            name: "REGION",
            kind: .variable,
            value: VaultFixture.variableValue
        )
        let oldSecret = try harness.itemRecord(secret)

        let newRecovery = try await harness.manager.rotateDEK(password: VaultFixture.password)
        newRecovery.wipe()

        let rotated = try harness.itemRecord(secret)
        #expect(rotated.valueCiphertext != oldSecret.valueCiphertext)
        #expect(rotated.valueFingerprint != oldSecret.valueFingerprint)
        #expect(rotated.syncedValueCiphertext != oldSecret.syncedValueCiphertext)
        #expect(rotated.syncedFingerprint != oldSecret.syncedFingerprint)
        #expect(try harness.value(of: secret) == VaultFixture.secretValue)
        #expect(try harness.syncedValue(of: secret) == VaultFixture.syncedSecretValue)
        #expect(try harness.fingerprintMatches(rotated.valueFingerprint, value: VaultFixture.secretValue, id: secret))
        #expect(
            try harness.fingerprintMatches(rotated.syncedFingerprint, value: VaultFixture.syncedSecretValue, id: secret)
        )
        #expect(try harness.value(of: variable) == VaultFixture.variableValue)
        // Status inputs are unchanged: still modified (value differs from the synced value).
        #expect(rotated.valueFingerprint != rotated.syncedFingerprint)
    }

    @Test func rotationRecomputesSyncedFingerprintFromAnEqualValue() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        let repo = try harness.seedRepository()
        let id = try harness.insertItem(repo: repo, name: "API_TOKEN", value: VaultFixture.secretValue)
        // Synced and equal, but without a synced ciphertext ("Accept GitHub").
        var record = try harness.itemRecord(id)
        record.syncedName = record.name
        record.syncedFingerprint = record.valueFingerprint
        try ConfigStore(database: harness.database).updateItem(record)

        let newRecovery = try await harness.manager.rotateDEK(password: VaultFixture.password)
        newRecovery.wipe()

        let rotated = try harness.itemRecord(id)
        #expect(rotated.syncedFingerprint == rotated.valueFingerprint)
        #expect(rotated.syncedFingerprint != record.syncedFingerprint)
    }

    @Test func rotationClearsAnUnrecoverableSyncedFingerprint() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        let repo = try harness.seedRepository()
        let id = try harness.insertItem(repo: repo, name: "API_TOKEN", value: VaultFixture.secretValue)
        var record = try harness.itemRecord(id)
        record.syncedName = record.name
        record.syncedFingerprint = Data(repeating: 0x5A, count: record.valueFingerprint?.count ?? 0)
        try ConfigStore(database: harness.database).updateItem(record)

        let newRecovery = try await harness.manager.rotateDEK(password: VaultFixture.password)
        newRecovery.wipe()
        #expect(try harness.itemRecord(id).syncedFingerprint == nil)
    }

    @Test func rotationAbortsWithoutChangesWhenARowDoesNotDecrypt() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        let repo = try harness.seedRepository()
        let id = try harness.insertItem(repo: repo, name: "API_TOKEN", value: VaultFixture.secretValue)
        var record = try harness.itemRecord(id)
        record.name = "RENAMED_WITHOUT_REENCRYPTION"
        try ConfigStore(database: harness.database).updateItem(record)
        let before = try harness.vaultRecord()

        let error = await vaultError {
            _ = try await harness.manager.rotateDEK(password: VaultFixture.password)
        }
        #expect(error == .corrupted(.fieldDecryptionFailed))
        #expect(try harness.vaultRecord() == before)
        #expect(harness.manager.state == .unlocked)
        #expect(harness.session.context == (try before.keyContext()))
    }

    @Test func rotateDEKRequiresTheMasterPassword() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        let error = await vaultError {
            _ = try await harness.manager.rotateDEK(password: VaultFixture.otherPassword)
        }
        #expect(error == .wrongPassword)
    }

    /// D9: a database copy taken before a rotation, opened with the credentials valid at that time,
    /// cannot decrypt anything written after the rotation.
    @Test func preRotationCopyCannotOpenDataWrittenAfterRotation() async throws {
        let temporary = try VaultTemporaryDirectory()
        defer { temporary.remove() }
        let live = try VaultHarness(database: DatabaseFactory.openOnDisk(directory: temporary.directory("live")))
        let oldRecovery = try await live.manager.create(password: VaultFixture.password)
        defer { oldRecovery.wipe() }
        let repo = try live.seedRepository()
        let before = try live.insertItem(repo: repo, name: "OLD_SECRET", value: VaultFixture.secretValue)

        // Copy the database files (the checkpoint after key writes leaves the WAL empty).
        try live.manager.checkpoint()
        let copyDirectory = temporary.directory("copy")
        try FileManager.default.createDirectory(at: copyDirectory, withIntermediateDirectories: true)
        let liveFile = try #require(live.database.fileURL)
        try FileManager.default.copyItem(
            at: liveFile,
            to: copyDirectory.appendingPathComponent(DatabaseFactory.databaseFileName)
        )

        let newRecovery = try await live.manager.changePassword(
            current: VaultFixture.password,
            new: VaultFixture.otherPassword,
            rotate: true
        )
        newRecovery?.wipe()
        let after = try live.insertItem(repo: repo, name: "NEW_SECRET", value: VaultFixture.variableValue)
        let newRecord = try live.itemRecord(after)

        let copy = try VaultHarness(database: DatabaseFactory.openOnDisk(directory: copyDirectory))
        try await copy.manager.unlock(password: VaultFixture.password)
        #expect(try copy.value(of: before) == VaultFixture.secretValue)
        let newCiphertext = try #require(newRecord.valueCiphertext)
        #expect(throws: VaultError.corrupted(.fieldDecryptionFailed)) {
            try copy.session.withKeys { keys in
                _ = try keys.open(newCiphertext, for: VaultHarness.valueAAD(newRecord))
            }
        }
        // The old recovery key opens only the old copy, never the live vault.
        let liveRecovery = try #require(try live.records.fetchKeyWrap(.recovery)).model()
        #expect(throws: VaultError.invalidRecoveryKey) {
            _ = try KeyWrap.unwrap(liveRecovery, recoveryKey: oldRecovery, context: live.vaultRecord().keyContext())
        }
    }

    @Test func keyWritesLeaveTheWALEmpty() async throws {
        let temporary = try VaultTemporaryDirectory()
        defer { temporary.remove() }
        let harness = try VaultHarness(database: DatabaseFactory.openOnDisk(directory: temporary.directory("vault")))
        let recoveryKey = try await harness.manager.create(password: VaultFixture.password)
        defer { recoveryKey.wipe() }
        let walURL = try #require(harness.database.fileURL).path + "-wal"

        func walSize() throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: walURL)
            return (attributes[.size] as? NSNumber)?.intValue ?? -1
        }
        #expect(try walSize() == 0)

        let rotated = try await harness.manager.rotateDEK(password: VaultFixture.password)
        rotated.wipe()
        #expect(try walSize() == 0)

        let recovery = try await harness.manager.newRecoveryKey(password: VaultFixture.password)
        recovery.wipe()
        #expect(try walSize() == 0)
    }

    // MARK: - New recovery key

    @Test func newRecoveryKeyReplacesTheOldOne() async throws {
        let (harness, oldRecovery) = try await VaultHarness.created()
        defer { oldRecovery.wipe() }
        let before = try harness.vaultRecord()
        let newRecovery = try await harness.manager.newRecoveryKey(password: VaultFixture.password)
        defer { newRecovery.wipe() }
        let after = try harness.vaultRecord()
        #expect(after.dekVersion == before.dekVersion)

        let wrap = try #require(try harness.records.fetchKeyWrap(.recovery)).model()
        #expect(throws: VaultError.invalidRecoveryKey) {
            _ = try KeyWrap.unwrap(wrap, recoveryKey: oldRecovery, context: after.keyContext())
        }
        _ = try KeyWrap.unwrap(wrap, recoveryKey: newRecovery, context: after.keyContext())

        let error = await vaultError {
            _ = try await harness.manager.newRecoveryKey(password: VaultFixture.otherPassword)
        }
        #expect(error == .wrongPassword)
    }

    // MARK: - Reset

    @Test func resetVaultErasesEverything() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        let repo = try harness.seedRepository()
        try harness.insertItem(repo: repo, name: "API_TOKEN", value: VaultFixture.secretValue)
        try await harness.manager.enableBiometrics(password: VaultFixture.password)
        harness.biometrics.seedItem(account: "touchid-v1-orphan", bytes: Data([1]))

        let wrongError = await vaultError {
            try await harness.manager.resetVault(password: VaultFixture.otherPassword)
        }
        #expect(wrongError == .wrongPassword)
        #expect(harness.manager.state == .unlocked)

        try await harness.manager.resetVault(password: VaultFixture.password)
        #expect(harness.manager.state == .noVault)
        #expect(harness.session.isLocked)
        #expect(try harness.records.fetchVault() == nil)
        #expect(try RepoStore(database: harness.database).fetchAll().isEmpty)
        #expect(harness.biometrics.accounts.isEmpty)
        #expect(harness.lockHook.value == 1)

        let again = try await harness.manager.create(password: VaultFixture.otherPassword)
        again.wipe()
        #expect(harness.manager.state == .unlocked)
    }

    /// The lock screen's last resort when both the password and the recovery key are gone: no
    /// key can be checked, so it erases without one, like Reset vault.
    @Test func eraseForgottenVaultErasesALockedVaultWithoutThePassword() async throws {
        let (harness, recoveryKey) = try await VaultHarness.created()
        defer { recoveryKey.wipe() }
        let repo = try harness.seedRepository()
        try harness.insertItem(repo: repo, name: "API_TOKEN", value: VaultFixture.secretValue)
        try await harness.manager.enableBiometrics(password: VaultFixture.password)
        harness.manager.lock()

        try await harness.manager.eraseForgottenVault()

        #expect(harness.manager.state == .noVault)
        #expect(try harness.records.fetchVault() == nil)
        #expect(try RepoStore(database: harness.database).fetchAll().isEmpty)
        #expect(harness.biometrics.accounts.isEmpty, "A Touch ID item would outlive the vault")
        let again = try await harness.manager.create(password: VaultFixture.otherPassword)
        again.wipe()
        #expect(harness.manager.state == .unlocked)
    }

    @Test func eraseForgottenVaultNeedsAVault() async throws {
        let harness = try VaultHarness()
        let error = await vaultError {
            try await harness.manager.eraseForgottenVault()
        }
        #expect(error == .notInitialized)
    }
}
