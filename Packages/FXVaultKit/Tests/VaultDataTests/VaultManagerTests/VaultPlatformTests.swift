import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore
import SharingKit

@Suite("Vault platform adapters")
struct VaultPlatformTests {
    // MARK: - KeychainManager (pure parts; no real keychain access)

    @Test func itemQueryMatchesTheDesign() throws {
        let query = KeychainManager.itemQuery(account: "touchid-v1-00", accessGroup: FakeBuildCapabilities.defaultAccessGroup)
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == BiometricKeyAccount.service)
        #expect(query[kSecAttrAccount as String] as? String == "touchid-v1-00")
        #expect(query[kSecAttrAccessGroup as String] as? String == FakeBuildCapabilities.defaultAccessGroup)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        let all = KeychainManager.itemQuery(account: nil, accessGroup: FakeBuildCapabilities.defaultAccessGroup)
        #expect(all[kSecAttrAccount as String] == nil)
    }

    @Test func loadErrorMapping() {
        #expect(KeychainManager.loadError(for: errSecItemNotFound, isLockedOut: false) == .biometryInvalidated)
        #expect(KeychainManager.loadError(for: errSecAuthFailed, isLockedOut: false) == .biometryInvalidated)
        #expect(KeychainManager.loadError(for: errSecAuthFailed, isLockedOut: true) == .biometryUnavailable(.lockout))
        #expect(KeychainManager.loadError(for: errSecUserCanceled, isLockedOut: false) == .cancelled)
        #expect(
            KeychainManager.loadError(for: errSecMissingEntitlement, isLockedOut: false)
                == .biometryUnavailable(.unsignedBuild)
        )
        #expect(KeychainManager.loadError(for: errSecParam, isLockedOut: false) == .biometryUnavailable(.notAvailable))
        #expect(
            KeychainManager.loadError(for: OSStatus(Self.code(.userFallback)), isLockedOut: false)
                == .passwordFallbackRequested
        )
        #expect(KeychainManager.loadError(for: OSStatus(Self.code(.userCancel)), isLockedOut: false) == .cancelled)
    }

    @Test func presenceMapping() throws {
        #expect(try KeychainManager.presence(for: errSecInteractionNotAllowed))
        #expect(try KeychainManager.presence(for: errSecSuccess))
        #expect(try !KeychainManager.presence(for: errSecItemNotFound))
        #expect(throws: VaultError.biometryUnavailable(.unsignedBuild)) {
            _ = try KeychainManager.presence(for: errSecMissingEntitlement)
        }
    }

    @Test func unsignedKeychainManagerRefusesWithoutTouchingTheKeychain() throws {
        let manager = KeychainManager(accessGroup: nil, authManager: BiometricAuthManager())
        let dek = SecretBytes(count: Limits.dekBytes)
        defer { dek.wipe() }
        #expect(throws: VaultError.biometryUnavailable(.unsignedBuild)) {
            try manager.store(dek, account: "touchid-v1-00")
        }
        #expect(throws: VaultError.biometryUnavailable(.unsignedBuild)) {
            _ = try manager.load(account: "touchid-v1-00", prompt: VaultFixture.prompt)
        }
        #expect(throws: VaultError.biometryUnavailable(.unsignedBuild)) {
            try manager.delete(account: "touchid-v1-00")
        }
        #expect(try !manager.contains(account: "touchid-v1-00"))
        #expect(try manager.allAccounts().isEmpty)
        manager.invalidateAuthentication()
    }

    @Test func accountNameUsesLowercaseHex() {
        let vaultID = Data([0x00, 0x0F, 0xA0, 0xFF] + Array(repeating: UInt8(0x01), count: Limits.vaultIDBytes - 4))
        let name = BiometricKeyAccount.name(vaultID: vaultID)
        #expect(name == "touchid-v1-000fa0ff" + String(repeating: "01", count: Limits.vaultIDBytes - 4))
    }

    // MARK: - LAError mapping

    @Test func laErrorMapping() {
        #expect(BiometricAuthManager.unavailableReason(forLAErrorCode: Self.code(.biometryLockout)) == .lockout)
        #expect(BiometricAuthManager.unavailableReason(forLAErrorCode: Self.code(.biometryNotEnrolled)) == .notEnrolled)
        #expect(BiometricAuthManager.unavailableReason(forLAErrorCode: Self.code(.passcodeNotSet)) == .passcodeNotSet)
        #expect(
            BiometricAuthManager.unavailableReason(forLAErrorCode: Self.code(.biometryNotAvailable)) == .notAvailable
        )
        #expect(BiometricAuthManager.unavailableReason(forLAErrorCode: Self.code(.userCancel)) == nil)
        #expect(BiometricAuthManager.unavailableReason(forLAErrorCode: nil) == nil)
        #expect(BiometricAuthManager.isCancellation(laErrorCode: Self.code(.userCancel)))
        #expect(!BiometricAuthManager.isCancellation(laErrorCode: Self.code(.userFallback)))
        #expect(BiometricAuthManager.isPasswordFallback(laErrorCode: Self.code(.userFallback)))
        #expect(!BiometricAuthManager.isPasswordFallback(laErrorCode: Self.code(.userCancel)))
        #expect(BiometricAuthManager.isCancellation(laErrorCode: Self.code(.appCancel)))
        #expect(!BiometricAuthManager.isCancellation(laErrorCode: Self.code(.biometryLockout)))
    }

    @Test func invalidateWithoutAPromptIsHarmless() {
        let manager = BiometricAuthManager()
        manager.invalidate()
        let context = manager.promptContext(for: VaultFixture.prompt)
        #expect(context.localizedReason == VaultFixture.prompt.reason)
        #expect(context.localizedFallbackTitle == VaultFixture.prompt.fallbackTitle)
        #expect(context.touchIDAuthenticationAllowableReuseDuration == 0)
        manager.invalidate()
        #expect(manager.silentContext().interactionNotAllowed)
    }

    // MARK: - BuildCapabilities

    @Test func bootSessionIsReadableAndStable() throws {
        let capabilities = BuildCapabilities()
        let first = try #require(capabilities.bootSessionID())
        #expect(!first.isEmpty)
        #expect(capabilities.bootSessionID() == first)
    }

    @Test func accessGroupSelection() {
        #expect(BuildCapabilities.accessGroup(fromEntitlement: nil) == nil)
        #expect(BuildCapabilities.accessGroup(fromEntitlement: [String]()) == nil)
        #expect(
            BuildCapabilities.accessGroup(fromEntitlement: ["TEAM.other", "TEAM.io.fractalx.fxvault"])
                == "TEAM.io.fractalx.fxvault"
        )
        #expect(BuildCapabilities.accessGroup(fromEntitlement: ["TEAM.other"]) == "TEAM.other")
    }

    @Test func unsignedTestRunnerHasNoAccessGroup() {
        // `swift test` runs unsigned (no keychain-access-groups entitlement).
        #expect(BuildCapabilities().keychainAccessGroup == nil)
    }

    // MARK: - Password rules

    @Test func passwordRequirementRules() {
        let start = ManualClock.defaultStart
        var vault = VaultRecord(
            vaultID: Data(count: Limits.vaultIDBytes),
            kcv: Data(count: Limits.kcvBytes),
            biometryStateHash: Data("a".utf8),
            lastPasswordUnlockAt: start,
            lastPasswordBootSession: "boot",
            createdAt: start
        )
        let maxAge = Timeouts.passwordMaxAge.timeInterval
        func reason(now: Date = start, boot: String? = "boot", hash: Data? = Data("a".utf8)) -> PasswordRequiredReason? {
            PasswordRules.passwordRequirement(vault: vault, now: now, bootSession: boot, currentStateHash: hash)
        }
        #expect(reason() == nil)
        #expect(reason(now: start.addingTimeInterval(maxAge)) == nil)
        #expect(reason(now: start.addingTimeInterval(maxAge + 1)) == .periodic)
        #expect(reason(now: start.addingTimeInterval(-1)) == .periodic)
        #expect(reason(boot: "other") == .restart)
        #expect(reason(boot: nil) == .restart)
        #expect(reason(hash: Data("b".utf8)) == .biometryChanged)
        #expect(reason(hash: nil) == nil)
        #expect(reason(now: start.addingTimeInterval(maxAge + 1), boot: "other") == .restart)
        vault.lastPasswordUnlockAt = nil
        #expect(reason() == .periodic)
        vault.lastPasswordBootSession = nil
        #expect(reason() == .restart)
    }

    // MARK: - Argon2idSharingDeriver

    @Test func sharingDeriverMatchesArgon2id() async throws {
        let salt = Array(repeating: UInt8(0x07), count: Limits.kdfSaltBytes)
        let parameters = KeyDerivationParametersModel(
            opsLimit: KDFParameters.testingOpsLimit,
            memLimitKiB: UInt32(KDFParameters.testingMemoryBytes / UInt64(Limits.bytesPerKiB)),
            parallelism: 1,
            salt: salt
        )
        let passphrase = SecretBytes(utf8: VaultFixture.password)
        defer { passphrase.wipe() }
        let derived = try await Argon2idSharingDeriver().deriveKey(passphrase: passphrase, parameters: parameters)
        defer { derived.wipe() }
        let expected = try Argon2id.deriveKey(password: passphrase, salt: Data(salt), parameters: .testing)
        #expect(derived.count == Limits.dekBytes)
        #expect(expected.withUnsafeBytes { derived.constantTimeEquals(Data($0)) })
    }

    @Test func sharingDeriverRejectsParallelismOtherThanOne() async throws {
        let parameters = KeyDerivationParametersModel(
            opsLimit: KDFParameters.testingOpsLimit,
            memLimitKiB: UInt32(KDFParameters.testingMemoryBytes / UInt64(Limits.bytesPerKiB)),
            parallelism: 2,
            salt: Array(repeating: 0, count: Limits.kdfSaltBytes)
        )
        let passphrase = SecretBytes(utf8: VaultFixture.password)
        defer { passphrase.wipe() }
        await #expect(throws: CryptoError.invalidKDFInput) {
            _ = try await Argon2idSharingDeriver().deriveKey(passphrase: passphrase, parameters: parameters)
        }
    }

    private static func code(_ code: LAError.Code) -> Int {
        code.rawValue
    }
}
