import Dispatch
import Foundation
import os
import VaultCore
import VaultCrypto
import VaultStore

/// The vault lifecycle: create, unlock, lock, password and recovery changes, DEK rotation, Touch
/// ID and reset (§5.1–§5.8, D8, D9, D14, D30).
///
/// - **Keys** live only in ``session`` (``VaultSession``), which every repository shares.
/// - **Argon2id and Touch ID run off the caller's actor**: every async method is `@concurrent`,
///   and the blocking keychain read runs on a dedicated dispatch queue.
/// - **Operations are serialized** (one at a time, in order). ``lock()`` is not: it is
///   synchronous and wins over anything in flight. An unlock or rotation that was running when
///   ``lock()`` was called fails with `VaultError.locked` and installs nothing.
/// - **Key writes are checkpointed**: after every commit that touches `vaults` or `key_wraps`,
///   `PRAGMA wal_checkpoint(TRUNCATE)` runs (D10). A checkpoint failure is logged, never thrown,
///   because the commit already happened (a recovery key must still reach the user).
///
/// Errors: `VaultError` for vault outcomes (wrong password, locked, corrupted, Touch ID states),
/// ``PasswordPolicyError`` for a weak new password, `StoreError` for database failures and
/// `CryptoError` when the KDF itself fails.
public final class VaultManager: Sendable {
    /// The shared session (database + keys) for every repository.
    public let session: VaultSession
    /// The KDF configuration (`.production` in the app, `.testing` in tests and previews).
    public let policy: KDFPolicy

    private let records: VaultRecordStore
    private let biometricStore: any BiometricKeyStoring
    private let capabilities: any BuildCapabilitiesProviding
    private let clock: any VaultClock
    private let onLock: @Sendable () -> Void
    private let gate = VaultOperationGate()
    private let lifecycle: OSAllocatedUnfairLock<Lifecycle>

    private struct Lifecycle: Sendable {
        var hasVault: Bool
        /// Incremented by every ``lock()``; an unlock installs keys only if it is unchanged.
        var lockEpoch: UInt64 = 0
        /// Touch ID turned itself off (see ``VaultManager/isBiometricsTurnedOffAutomatically``).
        var isBiometricsTurnedOffAutomatically = false
    }

    /// Serial queue for blocking Touch ID keychain reads (the prompt can stay up for seconds).
    private static let keychainQueue = DispatchQueue(
        label: VaultManagerConstants.keychainQueueLabel,
        qos: .userInitiated
    )

    /// - Parameters:
    ///   - session: the session over the migrated vault database.
    ///   - policy: `.production` in the app; `.testing` only in tests and previews.
    ///   - biometricStore: ``KeychainManager`` in the app, ``FakeBiometricKeyStore`` in tests.
    ///   - capabilities: ``BuildCapabilities`` in the app, ``FakeBuildCapabilities`` in tests.
    ///   - clock: wall time for the 14-day rule and timestamps.
    ///   - onLock: runs synchronously inside ``lock()`` right after the keys are dropped (Phase A,
    ///     §5.8): purge the gh token cache here. Must not block or suspend.
    /// - Throws: `StoreError` if the vault row cannot be read.
    public init(
        session: VaultSession,
        policy: KDFPolicy,
        biometricStore: any BiometricKeyStoring,
        capabilities: any BuildCapabilitiesProviding,
        clock: any VaultClock = SystemClock(),
        onLock: @escaping @Sendable () -> Void = {}
    ) throws {
        self.session = session
        self.policy = policy
        records = VaultRecordStore(database: session.database)
        self.biometricStore = biometricStore
        self.capabilities = capabilities
        self.clock = clock
        self.onLock = onLock
        lifecycle = OSAllocatedUnfairLock(initialState: Lifecycle(hasVault: try records.hasVault()))
    }

    // MARK: - State

    /// The current lifecycle state.
    public var state: VaultState {
        lifecycle.withLock { lifecycle in
            guard lifecycle.hasVault else { return .noVault }
            return session.isLocked ? .locked : .unlocked
        }
    }

    /// The re-authentication gate for sensitive operations (D30, §5.6).
    public var reauthGate: ReauthGate {
        ReauthGate(manager: self)
    }

    // MARK: - Create (onboarding)

    /// Creates the vault and leaves it unlocked (§5.1). Returns the recovery key, which is never
    /// stored: show it once, then let the caller wipe it.
    ///
    /// If ``lock()`` runs while this is in progress, the vault is still created but stays locked;
    /// the recovery key is returned either way.
    ///
    /// - Throws: ``PasswordPolicyError/tooWeak(_:)``; `VaultError.alreadyInitialized`.
    @concurrent
    public func create(password: String) async throws -> RecoveryKey {
        try PasswordRules.validateNewPassword(password)
        return try await gate.run {
            guard try !records.hasVault() else { throw VaultError.alreadyInitialized }
            let epoch = lockEpoch
            let keys = try UnlockedKeys.generate(vaultID: KeyHierarchy.generateVaultID())
            let passwordWrap = try await Self.wrap(keys, password: password, policy: policy)
            let recoveryKey = RecoveryKey.generate()
            do {
                let recoveryWrap = try KeyWrap.wrap(keys, recoveryKey: recoveryKey)
                let now = clock.now
                var vault = VaultRecord(
                    vaultID: keys.vaultID,
                    dekVersion: Int(keys.dekVersion),
                    kcv: keys.kcv,
                    createdAt: now
                )
                vault.recordPasswordCheck(at: now, bootSession: capabilities.bootSessionID())
                try session.database.write { tx in
                    try records.insertVault(vault, in: tx)
                    try records.saveKeyWrap(KeyWrapRecord(passwordWrap, updatedAt: now), in: tx)
                    try records.saveKeyWrap(KeyWrapRecord(recoveryWrap, updatedAt: now), in: tx)
                }
            } catch {
                recoveryKey.wipe()
                if case StoreError.constraintViolation(.primaryKey) = error { throw VaultError.alreadyInitialized }
                throw error
            }
            lifecycle.withLock { $0.hasVault = true }
            checkpointAfterKeyWrite()
            do {
                try install(keys, ifEpoch: epoch)
            } catch {
                VaultManagerConstants.log.info("Vault created while a lock happened; it stays locked")
            }
            VaultManagerConstants.log.info("Vault created")
            return recoveryKey
        }
    }

    // MARK: - Unlock and lock

    /// Unlocks with the master password and records the check for the restart and 14-day rules.
    /// When the Touch ID enrollment changed since Touch ID was enabled, the unusable item is
    /// deleted and Touch ID turned off, so the app can offer to enable it again.
    ///
    /// - Throws: `VaultError.wrongPassword`, `.notInitialized`, `.corrupted(...)` (tampered wrap,
    ///   key-check mismatch), `.locked` if ``lock()`` ran meanwhile.
    @concurrent
    public func unlock(password: String) async throws {
        try await gate.run {
            try requireVault()
            let epoch = lockEpoch
            let keys = try await unwrapWithPassword(password)
            try recordPasswordCheck()
            dropBiometricsIfEnrollmentChanged()
            guard session.isLocked else { return }
            try install(keys, ifEpoch: epoch)
            VaultManagerConstants.log.info("Vault unlocked with the master password")
        }
    }

    /// Unlocks with the Touch ID item (§5.5).
    ///
    /// - Throws: `VaultError.passwordRequired(reason:)` (restart, 14 days, enrollment change: the
    ///   item is deleted for the last), `.biometryUnavailable(reason)`, `.biometryInvalidated`
    ///   (the item was deleted; offer to re-enable after a password unlock), `.cancelled`,
    ///   `.passwordFallbackRequested` (focus the password field), `.corrupted(.keyCheckMismatch)`
    ///   (foreign item; deleted), `.locked`.
    @concurrent
    public func unlockWithBiometrics(prompt: BiometricPrompt) async throws {
        try await gate.run {
            try requireVault()
            let epoch = lockEpoch
            let keys = try await readBiometricKeys(prompt: prompt)
            guard session.isLocked else { return }
            try install(keys, ifEpoch: epoch)
            VaultManagerConstants.log.info("Vault unlocked with Touch ID")
        }
    }

    /// Lock procedure Phase A (§5.8), synchronous and safe from any thread: drops the keys,
    /// runs `onLock` (gh token purge), and invalidates the Touch ID context. The app then sets
    /// its phase to locked and starts Phase B (``checkpoint()`` among others).
    public func lock() {
        lifecycle.withLock { lifecycle in
            lifecycle.lockEpoch &+= 1
            session.lock()
        }
        onLock()
        biometricStore.invalidateAuthentication()
        VaultManagerConstants.log.info("Vault locked")
    }

    /// `PRAGMA wal_checkpoint(TRUNCATE)` (lock procedure Phase B, D10). Run it off the main
    /// actor; it can wait briefly for readers.
    public func checkpoint() throws {
        try session.database.checkpointTruncate()
    }

    // MARK: - Touch ID status

    /// Why the master password is required instead of Touch ID right now, or nil (§5.5).
    public func passwordRequirement() throws -> PasswordRequiredReason? {
        try PasswordRules.passwordRequirement(
            vault: loadVault(),
            now: clock.now,
            bootSession: capabilities.bootSessionID(),
            currentStateHash: capabilities.biometryStateHash()
        )
    }

    /// What the lock screen can offer, without any prompt.
    public func biometricUnlockStatus() throws -> BiometricUnlockStatus {
        try requireVault()
        let vault = try loadVault()
        return try evaluateBiometricUnlock(vault: vault, account: BiometricKeyAccount.name(vaultID: vault.vaultID))
    }

    /// True when Touch ID unlock is enabled for this vault (Preferences toggle).
    public func isBiometricsEnabled() throws -> Bool {
        try records.fetchVault()?.biometryStateHash != nil
    }

    /// True when FX Vault turned Touch ID off by itself since it was last enabled, disabled or
    /// acknowledged: a changed enrollment (seen by a password unlock, a Touch ID unlock or a
    /// ReauthGate check), an invalidated, missing or foreign item, or a failed item replacement.
    /// The app offers Touch ID once more after the next password unlock. Kept in memory for the
    /// life of the process.
    public var isBiometricsTurnedOffAutomatically: Bool {
        lifecycle.withLock { $0.isBiometricsTurnedOffAutomatically }
    }

    /// Clears ``isBiometricsTurnedOffAutomatically`` (the offer was answered, or Touch ID was
    /// changed in Settings).
    public func acknowledgeBiometricsTurnedOff() {
        lifecycle.withLock { $0.isBiometricsTurnedOffAutomatically = false }
    }

    /// Why Touch ID cannot be enabled on this build and Mac, or nil. `.unsignedBuild` disables the
    /// toggle with the note "Touch ID requires the official signed release." (§5.5).
    public func biometricsAvailability() -> BiometryUnavailableReason? {
        guard capabilities.hasKeychainAccessGroup else { return .unsignedBuild }
        return capabilities.biometryUnavailableReason()
    }

    // MARK: - Password and recovery (master password only, D30)

    /// Changes the master password (§5.2). With `rotate` (the default in the UI: "My password may
    /// be compromised: rotate the vault key"), it also rotates the DEK and returns the new
    /// recovery key; otherwise it re-wraps the DEK with a fresh salt and returns nil.
    ///
    /// - Throws: ``PasswordPolicyError/tooWeak(_:)``; `VaultError.wrongPassword`, `.locked`.
    @concurrent
    public func changePassword(current: String, new: String, rotate: Bool) async throws -> RecoveryKey? {
        try PasswordRules.validateNewPassword(new)
        return try await gate.run {
            try requireUnlocked()
            let epoch = lockEpoch
            let keys = try await unwrapWithPassword(current)
            if rotate {
                return try await rotateKeys(from: keys, newPassword: new, epoch: epoch)
            }
            let wrap = try await Self.wrap(keys, password: new, policy: policy)
            let now = clock.now
            let bootSession = capabilities.bootSessionID()
            try session.database.write { tx in
                guard var vault = try records.fetchVault(in: tx), vault.describes(keys) else { throw VaultError.locked }
                try records.saveKeyWrap(KeyWrapRecord(wrap, updatedAt: now), in: tx)
                vault.recordPasswordCheck(at: now, bootSession: bootSession)
                try records.updateVault(vault, in: tx)
            }
            checkpointAfterKeyWrite()
            VaultManagerConstants.log.info("Master password changed without rotation")
            return nil
        }
    }

    /// Recovery reset (D9, §5.2): opens the vault with the recovery key, sets `newPassword`,
    /// **always** rotates the DEK and returns the new recovery key. Works locked or unlocked and
    /// leaves the vault unlocked. The caller wipes `recoveryKey`.
    ///
    /// - Throws: ``PasswordPolicyError/tooWeak(_:)``; `VaultError.invalidRecoveryKey`,
    ///   `.corrupted(...)`, `.locked` if ``lock()`` ran meanwhile.
    @concurrent
    public func resetWithRecoveryKey(_ recoveryKey: RecoveryKey, newPassword: String) async throws -> RecoveryKey {
        try PasswordRules.validateNewPassword(newPassword)
        return try await gate.run {
            try requireVault()
            let epoch = lockEpoch
            let vault = try loadVault()
            let oldKeys = try KeyWrap.unwrap(
                loadWrap(.recovery),
                recoveryKey: recoveryKey,
                context: vault.keyContext()
            )
            return try await rotateKeys(from: oldKeys, newPassword: newPassword, epoch: epoch)
        }
    }

    /// Rotates the DEK (§5.2 `rotateDEK`) and returns the new recovery key. The password stays
    /// the same (new salt).
    ///
    /// - Throws: `VaultError.wrongPassword`, `.locked`, `.corrupted(.fieldDecryptionFailed)` if a
    ///   stored value no longer decrypts (nothing is changed then).
    @concurrent
    public func rotateDEK(password: String) async throws -> RecoveryKey {
        try await gate.run {
            try requireUnlocked()
            let epoch = lockEpoch
            let keys = try await unwrapWithPassword(password)
            return try await rotateKeys(from: keys, newPassword: password, epoch: epoch)
        }
    }

    /// Replaces the recovery key (Preferences, D30) without rotating the DEK. The old recovery
    /// key stops working.
    ///
    /// - Throws: `VaultError.wrongPassword`, `.locked`.
    @concurrent
    public func newRecoveryKey(password: String) async throws -> RecoveryKey {
        try await gate.run {
            try requireUnlocked()
            let keys = try await unwrapWithPassword(password)
            let recoveryKey = RecoveryKey.generate()
            do {
                let wrap = try KeyWrap.wrap(keys, recoveryKey: recoveryKey)
                let now = clock.now
                let bootSession = capabilities.bootSessionID()
                try session.database.write { tx in
                    guard var vault = try records.fetchVault(in: tx), vault.describes(keys) else {
                        throw VaultError.locked
                    }
                    try records.saveKeyWrap(KeyWrapRecord(wrap, updatedAt: now), in: tx)
                    vault.recordPasswordCheck(at: now, bootSession: bootSession)
                    try records.updateVault(vault, in: tx)
                }
            } catch {
                recoveryKey.wipe()
                throw error
            }
            checkpointAfterKeyWrite()
            VaultManagerConstants.log.info("Recovery key replaced")
            return recoveryKey
        }
    }

    // MARK: - Touch ID settings

    /// Enables Touch ID unlock (§5.5): deletes orphaned items of other vaults, stores the DEK in
    /// a `.biometryCurrentSet` item and records the enrollment fingerprint.
    ///
    /// - Throws: `VaultError.biometryUnavailable(.unsignedBuild)` in ad-hoc builds, other
    ///   `.biometryUnavailable` reasons, `.wrongPassword`, `.locked`.
    @concurrent
    public func enableBiometrics(password: String) async throws {
        try await gate.run {
            try requireUnlocked()
            if let reason = biometricsAvailability() { throw VaultError.biometryUnavailable(reason) }
            guard let stateHash = capabilities.biometryStateHash() else {
                throw VaultError.biometryUnavailable(.notAvailable)
            }
            let keys = try await unwrapWithPassword(password)
            let account = BiometricKeyAccount.name(vaultID: keys.vaultID)
            try removeOrphanedItems(keeping: account)
            let dek = keys.exportDEK()
            defer { dek.wipe() }
            try biometricStore.store(dek, account: account)
            do {
                try updateVault { vault in
                    vault.biometryStateHash = stateHash
                    vault.recordPasswordCheck(at: clock.now, bootSession: capabilities.bootSessionID())
                }
            } catch {
                try? biometricStore.delete(account: account)
                throw error
            }
            acknowledgeBiometricsTurnedOff()
            VaultManagerConstants.log.info("Touch ID enabled")
        }
    }

    /// Disables Touch ID unlock (master password only, D30): deletes the item and the stored
    /// enrollment fingerprint.
    ///
    /// - Throws: `VaultError.wrongPassword`, `.locked`.
    @concurrent
    public func disableBiometrics(password: String) async throws {
        try await gate.run {
            try requireUnlocked()
            let keys = try await unwrapWithPassword(password)
            if capabilities.hasKeychainAccessGroup {
                try biometricStore.delete(account: BiometricKeyAccount.name(vaultID: keys.vaultID))
            }
            try updateVault { vault in
                vault.biometryStateHash = nil
                vault.recordPasswordCheck(at: clock.now, bootSession: capabilities.bootSessionID())
            }
            acknowledgeBiometricsTurnedOff()
            VaultManagerConstants.log.info("Touch ID disabled")
        }
    }

    // MARK: - Reset

    /// Erases the vault (master password only, D30): locks, deletes every row of every table,
    /// and deletes every Touch ID item of the service. The state becomes ``VaultState/noVault``.
    ///
    /// - Throws: `VaultError.wrongPassword`, `.notInitialized`.
    @concurrent
    public func resetVault(password: String) async throws {
        try await gate.run {
            try requireVault()
            _ = try await unwrapWithPassword(password)
            lock()
            try session.database.write { tx in
                try records.eraseAllData(in: tx)
            }
            lifecycle.withLock { lifecycle in
                lifecycle.hasVault = false
                lifecycle.isBiometricsTurnedOffAutomatically = false
            }
            checkpointAfterKeyWrite()
            if capabilities.hasKeychainAccessGroup {
                for account in (try? biometricStore.allAccounts()) ?? [] {
                    try? biometricStore.delete(account: account)
                }
            }
            VaultManagerConstants.log.info("Vault reset")
        }
    }

    // MARK: - Re-authentication (ReauthGate)

    /// Verifies the master password while unlocked and records the check.
    func reauthenticate(password: String) async throws {
        try await gate.run {
            try requireUnlocked()
            let keys = try await unwrapWithPassword(password)
            try ensureInstalledKeysMatch(keys)
            try recordPasswordCheck()
        }
    }

    /// Verifies the Touch ID item (with the kcv) while unlocked. The password rules apply.
    func reauthenticate(prompt: BiometricPrompt) async throws {
        try await gate.run {
            try requireUnlocked()
            let keys = try await readBiometricKeys(prompt: prompt)
            try ensureInstalledKeysMatch(keys)
        }
    }

    // MARK: - Private: state

    private var lockEpoch: UInt64 {
        lifecycle.withLock { $0.lockEpoch }
    }

    private func requireVault() throws(VaultError) {
        guard lifecycle.withLock({ $0.hasVault }) else { throw .notInitialized }
    }

    private func requireUnlocked() throws(VaultError) {
        try requireVault()
        guard !session.isLocked else { throw .locked }
    }

    /// Installs `keys` unless ``lock()`` ran since `epoch` was read.
    private func install(_ keys: UnlockedKeys, ifEpoch epoch: UInt64) throws(VaultError) {
        let installed = lifecycle.withLock { lifecycle -> Bool in
            guard lifecycle.lockEpoch == epoch else { return false }
            lifecycle.hasVault = true
            session.install(keys)
            return true
        }
        guard installed else { throw .locked }
    }

    private func ensureInstalledKeysMatch(_ keys: UnlockedKeys) throws {
        let context = keys.context
        guard try session.withKeys({ $0.matches(context) }) else { throw VaultError.locked }
    }

    // MARK: - Private: records

    private func loadVault() throws -> VaultRecord {
        guard let vault = try records.fetchVault() else { throw VaultError.notInitialized }
        return vault
    }

    private func loadWrap(_ method: VaultStore.KeyWrapMethod) throws -> KeyWrapModel {
        guard let record = try records.fetchKeyWrap(method) else { throw VaultError.corrupted(.missingKeyWrap) }
        return try record.model()
    }

    /// Reads, changes and writes the vault row in one transaction, then checkpoints.
    private func updateVault(_ change: (inout VaultRecord) -> Void) throws {
        try session.database.write { tx in
            guard var vault = try records.fetchVault(in: tx) else { throw VaultError.notInitialized }
            change(&vault)
            try records.updateVault(vault, in: tx)
        }
        checkpointAfterKeyWrite()
    }

    private func recordPasswordCheck() throws {
        let now = clock.now
        let bootSession = capabilities.bootSessionID()
        try updateVault { $0.recordPasswordCheck(at: now, bootSession: bootSession) }
    }

    /// D10: never throws, because the commit before it already happened.
    private func checkpointAfterKeyWrite() {
        do {
            try session.database.checkpointTruncate()
        } catch {
            VaultManagerConstants.log.error("WAL checkpoint after a key write failed")
        }
    }

    // MARK: - Private: password

    private func unwrapWithPassword(_ password: String) async throws -> UnlockedKeys {
        let vault = try loadVault()
        return try await Self.unwrap(
            loadWrap(.password),
            password: password,
            context: vault.keyContext(),
            policy: policy
        )
    }

    @concurrent
    private static func unwrap(
        _ wrap: KeyWrapModel,
        password: String,
        context: VaultKeyContext,
        policy: KDFPolicy
    ) async throws -> UnlockedKeys {
        try KeyWrap.unwrap(wrap, password: password, context: context, policy: policy)
    }

    @concurrent
    private static func wrap(_ keys: UnlockedKeys, password: String, policy: KDFPolicy) async throws -> KeyWrapModel {
        try KeyWrap.wrap(keys, password: password, policy: policy)
    }

    // MARK: - Private: rotation (§5.2 rotateDEK)

    /// Rotates from `oldKeys` to a new DEK in one transaction: re-encrypts every value, re-wraps
    /// for `newPassword` and a new recovery key, stores the new kcv, and installs the new keys as
    /// the last step inside the transaction (so no repository write can slip in under the old
    /// DEK). Then checkpoints and replaces the Touch ID item.
    private func rotateKeys(from oldKeys: UnlockedKeys, newPassword: String, epoch: UInt64) async throws -> RecoveryKey {
        let newKeys = oldKeys.rotated()
        let passwordWrap = try await Self.wrap(newKeys, password: newPassword, policy: policy)
        let recoveryKey = RecoveryKey.generate()
        let report: DEKRotationReportModel
        do {
            let recoveryWrap = try KeyWrap.wrap(newKeys, recoveryKey: recoveryKey)
            let now = clock.now
            let bootSession = capabilities.bootSessionID()
            let rotator = DEKRotator(database: session.database)
            var installedNewKeys = false
            do {
                report = try session.database.write { tx in
                    guard var vault = try records.fetchVault(in: tx), vault.describes(oldKeys) else {
                        throw VaultError.locked
                    }
                    let report = try rotator.reencryptAll(from: oldKeys, to: newKeys, in: tx)
                    try records.saveKeyWrap(KeyWrapRecord(passwordWrap, updatedAt: now), in: tx)
                    try records.saveKeyWrap(KeyWrapRecord(recoveryWrap, updatedAt: now), in: tx)
                    vault.adopt(newKeys)
                    vault.recordPasswordCheck(at: now, bootSession: bootSession)
                    try records.updateVault(vault, in: tx)
                    try install(newKeys, ifEpoch: epoch)
                    installedNewKeys = true
                    return report
                }
            } catch {
                // The commit failed after the new keys were installed: the database still holds
                // the old DEK, so drop the keys rather than keep a mismatched keyring.
                if installedNewKeys { lock() }
                throw error
            }
        } catch {
            recoveryKey.wipe()
            throw error
        }
        checkpointAfterKeyWrite()
        replaceBiometricItem(with: newKeys)
        VaultManagerConstants.log.info(
            """
            DEK rotated to version \(newKeys.dekVersion, privacy: .public): \
            \(report.values, privacy: .public) values, \(report.syncedValues, privacy: .public) synced values, \
            \(report.folderValues, privacy: .public) folder values, \
            \(report.syncedFingerprintsCleared, privacy: .public) synced fingerprints cleared
            """
        )
        return recoveryKey
    }

    // MARK: - Private: Touch ID

    /// The lock-screen decision, without UI. Order: build, enablement, password rules, hardware.
    private func evaluateBiometricUnlock(vault: VaultRecord, account: String) throws -> BiometricUnlockStatus {
        guard capabilities.hasKeychainAccessGroup else { return .unavailable(.unsignedBuild) }
        guard vault.biometryStateHash != nil, try biometricStore.contains(account: account) else {
            return .unavailable(.notEnabled)
        }
        if let reason = PasswordRules.passwordRequirement(
            vault: vault,
            now: clock.now,
            bootSession: capabilities.bootSessionID(),
            currentStateHash: capabilities.biometryStateHash()
        ) {
            return .passwordRequired(reason)
        }
        if let reason = capabilities.biometryUnavailableReason() {
            return .unavailable(reason)
        }
        return .available
    }

    /// Applies every Touch ID rule, reads the item (one prompt) and verifies it against the
    /// vault's key-check value. Invalid items are deleted and the enablement cleared.
    private func readBiometricKeys(prompt: BiometricPrompt) async throws -> UnlockedKeys {
        let vault = try loadVault()
        let context = try vault.keyContext()
        let account = BiometricKeyAccount.name(vaultID: vault.vaultID)
        switch try evaluateBiometricUnlock(vault: vault, account: account) {
        case .available:
            break
        case .unavailable(.notEnabled) where vault.biometryStateHash != nil:
            // Enabled, but the item is gone.
            try forgetBiometrics(account: account)
            throw VaultError.biometryInvalidated
        case .unavailable(let reason):
            throw VaultError.biometryUnavailable(reason)
        case .passwordRequired(let reason):
            if reason == .biometryChanged {
                try forgetBiometrics(account: account)
            }
            throw VaultError.passwordRequired(reason: reason)
        }

        let dek: SecretBytes
        do {
            dek = try await Self.loadDEK(from: biometricStore, account: account, prompt: prompt)
        } catch .biometryInvalidated {
            try forgetBiometrics(account: account)
            throw VaultError.biometryInvalidated
        }
        defer { dek.wipe() }
        do {
            return try UnlockedKeys(dekBytes: dek, context: context)
        } catch {
            VaultManagerConstants.log.error("Touch ID item failed the key check; deleted")
            try forgetBiometrics(account: account)
            throw error
        }
    }

    /// Runs the blocking keychain read on ``keychainQueue`` so no cooperative thread waits on the
    /// prompt.
    private static func loadDEK(
        from store: any BiometricKeyStoring,
        account: String,
        prompt: BiometricPrompt
    ) async throws(VaultError) -> SecretBytes {
        let result: Result<SecretBytes, VaultError> = await withCheckedContinuation { continuation in
            keychainQueue.async {
                continuation.resume(returning: Result { () throws(VaultError) in
                    try store.load(account: account, prompt: prompt)
                })
            }
        }
        return try result.get()
    }

    /// After a password unlock: a `.biometryCurrentSet` item can never be read again once the
    /// enrollment changed, so delete it and clear the enablement now. Otherwise the lock screen
    /// would keep requiring the password ("fingerprints changed") on every lock, and Settings
    /// would still show Touch ID as on. Skipped while Touch ID is unavailable (no state hash).
    /// Never fails the unlock.
    private func dropBiometricsIfEnrollmentChanged() {
        do {
            let vault = try loadVault()
            guard
                let enrolled = vault.biometryStateHash,
                let current = capabilities.biometryStateHash(),
                current != enrolled
            else { return }
            try forgetBiometrics(account: BiometricKeyAccount.name(vaultID: vault.vaultID))
            VaultManagerConstants.log.info("Touch ID enrollment changed; Touch ID turned off")
        } catch {
            VaultManagerConstants.log.error("Clearing a stale Touch ID enrollment failed")
        }
    }

    /// Deletes the item (best effort) and clears the enablement, so the UI offers to re-enable
    /// (``isBiometricsTurnedOffAutomatically``).
    private func forgetBiometrics(account: String) throws {
        try? biometricStore.delete(account: account)
        try updateVault { $0.biometryStateHash = nil }
        lifecycle.withLock { $0.isBiometricsTurnedOffAutomatically = true }
    }

    /// Deletes every item of the service whose account is not `account` (§5.5 enable).
    private func removeOrphanedItems(keeping account: String) throws {
        let orphans = try biometricStore.allAccounts().filter { $0 != account }
        for orphan in orphans {
            try biometricStore.delete(account: orphan)
        }
        if !orphans.isEmpty {
            VaultManagerConstants.log.info("Deleted \(orphans.count, privacy: .public) orphaned Touch ID items")
        }
    }

    /// After a rotation: replaces the item with the new DEK when Touch ID is enabled. On failure
    /// Touch ID is disabled (never left holding the old DEK).
    private func replaceBiometricItem(with keys: UnlockedKeys) {
        guard let vault = try? loadVault(), vault.biometryStateHash != nil else { return }
        let account = BiometricKeyAccount.name(vaultID: vault.vaultID)
        let dek = keys.exportDEK()
        defer { dek.wipe() }
        do {
            try biometricStore.delete(account: account)
            try biometricStore.store(dek, account: account)
        } catch {
            VaultManagerConstants.log.error("Touch ID item replacement failed; Touch ID disabled")
            try? forgetBiometrics(account: account)
        }
    }
}
