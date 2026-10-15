import Foundation
import LocalAuthentication
import os
import Security
import VaultCore

/// The live ``BiometricKeyStoring``: the DEK in a data-protection keychain item that only Touch ID
/// can read (§5.5, D14).
///
/// The item:
/// - `kSecClassGenericPassword`, service ``BiometricKeyAccount/service``, account
///   `touchid-v1-<vault_id hex>`, the access group from the signed entitlement;
/// - `kSecUseDataProtectionKeychain: true`, `kSecAttrSynchronizable: false`;
/// - access control `WhenPasscodeSetThisDeviceOnly` + `.biometryCurrentSet`, so adding or removing
///   a fingerprint makes the item unreadable.
///
/// Only Developer ID-signed builds with the embedded profile have the access group. Without it
/// (`accessGroup == nil`, ad-hoc builds) every operation throws
/// `.biometryUnavailable(.unsignedBuild)` and ``allAccounts()`` returns nothing.
///
/// macOS data-protection keychain rules this type follows (checked in v0.1.1; the queries are
/// built by the pure `…Query` functions below and unit-tested):
/// - every query sets `kSecUseDataProtectionKeychain` and the **full** entitled access group
///   (`<team id>.io.fractalx.fxvault`, read from the signed entitlement), never a bare suffix;
/// - the protection class travels inside the `SecAccessControl` only: `kSecAttrAccessible` is
///   never added next to `kSecAttrAccessControl` (`SecItemAdd` rejects the pair with
///   `errSecParam`);
/// - the interactive read passes a fresh `LAContext` through `kSecUseAuthenticationContext`, whose
///   `localizedReason` is the prompt text (`kSecUseOperationPrompt` is deprecated);
/// - presence checks and listings ask for **attributes only**, with an `LAContext` whose
///   `interactionNotAllowed` is set, so they can never show UI or return the DEK.
///
/// `SecItemAdd` needs the DEK as `Data`. That copy is zeroed right after the call; the
/// bridged dictionary may hold a short-lived reference the process cannot wipe (documented
/// residual risk, §5.12).
public struct KeychainManager: BiometricKeyStoring {
    /// The `keychain-access-groups` entry from the entitlement, or nil in ad-hoc builds.
    public let accessGroup: String?
    private let authManager: BiometricAuthManager

    /// - Parameters:
    ///   - accessGroup: ``BuildCapabilities/keychainAccessGroup``.
    ///   - authManager: the app's single ``BiometricAuthManager`` (invalidated on lock).
    public init(accessGroup: String?, authManager: BiometricAuthManager) {
        self.accessGroup = accessGroup
        self.authManager = authManager
    }

    // MARK: - BiometricKeyStoring

    public func store(_ dek: SecretBytes, account: String) throws(VaultError) {
        let group = try requireAccessGroup()
        try delete(account: account)

        guard let access = Self.biometricAccessControl() else {
            throw .biometryUnavailable(.notAvailable)
        }

        var data = dek.withUnsafeBytes { Data($0) }
        let status = Self.add(data: data, account: account, accessGroup: group, access: access)
        data.resetBytes(in: data.startIndex..<data.endIndex)
        guard status == errSecSuccess else {
            VaultManagerConstants.log.error("Touch ID item add failed: \(status, privacy: .public)")
            throw Self.storeError(for: status)
        }
    }

    public func load(account: String, prompt: BiometricPrompt) throws(VaultError) -> SecretBytes {
        let group = try requireAccessGroup()
        if let reason = authManager.unavailableReason() {
            throw .biometryUnavailable(reason)
        }
        let query = Self.readQuery(account: account, accessGroup: group, context: authManager.promptContext(for: prompt))

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            let isLockedOut = status == errSecAuthFailed && authManager.unavailableReason() == .lockout
            let error = Self.loadError(for: status, isLockedOut: isLockedOut)
            VaultManagerConstants.log.info("Touch ID item read ended: \(status, privacy: .public)")
            throw error
        }
        guard var data = result as? Data else { throw .corrupted(.invalidStoredValue) }
        return SecretBytes(wipingSource: &data)
    }

    public func contains(account: String) throws(VaultError) -> Bool {
        guard let group = accessGroup else { return false }
        let query = Self.presenceQuery(account: account, accessGroup: group, context: authManager.silentContext())
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return try Self.presence(for: status)
    }

    public func delete(account: String) throws(VaultError) {
        let group = try requireAccessGroup()
        let status = SecItemDelete(Self.itemQuery(account: account, accessGroup: group) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            VaultManagerConstants.log.error("Touch ID item delete failed: \(status, privacy: .public)")
            throw Self.storeError(for: status)
        }
    }

    public func allAccounts() throws(VaultError) -> [String] {
        guard let group = accessGroup else { return [] }
        let query = Self.listQuery(accessGroup: group, context: authManager.silentContext())

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let items = result as? [[String: Any]] ?? []
            return items.compactMap { $0[kSecAttrAccount as String] as? String }
        case errSecItemNotFound:
            return []
        default:
            VaultManagerConstants.log.error("Touch ID item listing failed: \(status, privacy: .public)")
            throw Self.storeError(for: status)
        }
    }

    public func invalidateAuthentication() {
        authManager.invalidate()
    }

    // MARK: - Internal (pure, unit-tested)

    /// The attributes that identify FX Vault's DEK items. `account == nil` matches every item
    /// of the service in the access group. `service` is overridden only by ``KeychainProbe``,
    /// which tests these exact attributes under its own service.
    static func itemQuery(
        account: String?,
        accessGroup: String,
        service: String = BiometricKeyAccount.service
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    /// `SecItemAdd` attributes: ``itemQuery(account:accessGroup:service:)`` plus the access control
    /// and the value. No `kSecAttrAccessible`: the protection class is inside `access`.
    static func addQuery(
        data: Data,
        account: String,
        accessGroup: String,
        access: SecAccessControl,
        service: String = BiometricKeyAccount.service
    ) -> [String: Any] {
        var query = itemQuery(account: account, accessGroup: accessGroup, service: service)
        query[kSecAttrAccessControl as String] = access
        query[kSecValueData as String] = data
        return query
    }

    /// The interactive read: the item's data, one match, through `context` (a fresh prompt
    /// context whose `localizedReason` is the prompt text).
    static func readQuery(account: String, accessGroup: String, context: LAContext) -> [String: Any] {
        var query = itemQuery(account: account, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    /// The presence check: attributes only (reading attributes needs no authentication, so the
    /// DEK is never requested), one match, through a context that never shows UI.
    static func presenceQuery(account: String, accessGroup: String, context: LAContext) -> [String: Any] {
        var query = itemQuery(account: account, accessGroup: accessGroup)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    /// Every item of the service in the access group: attributes only, without UI.
    static func listQuery(accessGroup: String, context: LAContext) -> [String: Any] {
        var query = itemQuery(account: nil, accessGroup: accessGroup)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    /// `WhenPasscodeSetThisDeviceOnly` + `.biometryCurrentSet` (§5.5): readable only after a
    /// Touch ID match with the fingerprints enrolled when the item was added, never synced or
    /// restored to another Mac. Nil if Security cannot build it.
    static func biometricAccessControl() -> SecAccessControl? {
        var accessError: Unmanaged<CFError>?
        let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet,
            &accessError
        )
        _ = accessError?.takeRetainedValue()
        return access
    }

    /// Maps a failed read (§5.5): missing item → invalidated, user cancel → cancelled, fallback
    /// button → password field, failed match → password field, lockout → password, missing
    /// entitlement → unsigned build.
    ///
    /// `errSecAuthFailed` is what the keychain returns when Touch ID did not recognize the
    /// finger (`LAError.authenticationFailed`). It never means the item is gone: an item
    /// invalidated by an enrollment change is not found (`errSecItemNotFound`), and
    /// ``VaultManager`` also detects enrollment changes from the domain state before any read.
    /// Treating it as invalidation would delete the item and turn Touch ID off after a few wet
    /// fingers, so it only sends the user to the password field.
    static func loadError(for status: OSStatus, isLockedOut: Bool) -> VaultError {
        switch status {
        case errSecAuthFailed where isLockedOut:
            return .biometryUnavailable(.lockout)
        case errSecAuthFailed:
            return .passwordFallbackRequested
        case errSecItemNotFound:
            return .biometryInvalidated
        case errSecUserCanceled:
            return .cancelled
        case errSecMissingEntitlement:
            return .biometryUnavailable(.unsignedBuild)
        case errSecInteractionNotAllowed:
            return .biometryUnavailable(.notAvailable)
        default:
            let code = Int(status)
            if BiometricAuthManager.isPasswordFallback(laErrorCode: code) {
                return .passwordFallbackRequested
            }
            if BiometricAuthManager.isCancellation(laErrorCode: code) {
                return .cancelled
            }
            return .biometryUnavailable(BiometricAuthManager.unavailableReason(forLAErrorCode: code) ?? .notAvailable)
        }
    }

    /// Maps the status of the presence check (§5.5): an attributes-only lookup answers
    /// `errSecSuccess` for a present item; `errSecInteractionNotAllowed` and `errSecAuthFailed`
    /// (an item that would need authentication) also mean present; a missing one
    /// `errSecItemNotFound`.
    static func presence(for status: OSStatus) throws(VaultError) -> Bool {
        switch status {
        case errSecSuccess, errSecInteractionNotAllowed, errSecAuthFailed:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw storeError(for: status)
        }
    }

    /// Maps a failed add, delete or listing.
    static func storeError(for status: OSStatus) -> VaultError {
        switch status {
        case errSecMissingEntitlement:
            .biometryUnavailable(.unsignedBuild)
        default:
            .biometryUnavailable(.notAvailable)
        }
    }

    // MARK: - Private

    private func requireAccessGroup() throws(VaultError) -> String {
        guard let accessGroup else { throw .biometryUnavailable(.unsignedBuild) }
        return accessGroup
    }

    /// Runs `SecItemAdd` in its own scope so the query (and its reference to `data`) is gone
    /// before the caller zeroes `data`.
    private static func add(data: Data, account: String, accessGroup: String, access: SecAccessControl) -> OSStatus {
        let query = addQuery(data: data, account: account, accessGroup: accessGroup, access: access)
        return SecItemAdd(query as CFDictionary, nil)
    }
}
