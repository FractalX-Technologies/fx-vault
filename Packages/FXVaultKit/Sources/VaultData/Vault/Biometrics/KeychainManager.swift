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

        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet,
            &accessError
        ) else {
            _ = accessError?.takeRetainedValue()
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
        var query = Self.itemQuery(account: account, accessGroup: group)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = authManager.promptContext(for: prompt)

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
        var query = Self.itemQuery(account: account, accessGroup: group)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = authManager.silentContext()

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if var data = result as? Data {
            data.resetBytes(in: data.startIndex..<data.endIndex)
        }
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
        var query = Self.itemQuery(account: nil, accessGroup: group)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecUseAuthenticationContext as String] = authManager.silentContext()

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
    /// of the service in the access group.
    static func itemQuery(account: String?, accessGroup: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: BiometricKeyAccount.service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    /// Maps a failed read (§5.5): missing or unreadable item → invalidated, user cancel →
    /// cancelled, fallback button → password field, lockout → password, missing entitlement →
    /// unsigned build.
    static func loadError(for status: OSStatus, isLockedOut: Bool) -> VaultError {
        switch status {
        case errSecAuthFailed where isLockedOut:
            return .biometryUnavailable(.lockout)
        case errSecItemNotFound, errSecAuthFailed:
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

    /// Maps the status of the presence check (§5.5): an item that needs authentication answers
    /// `errSecInteractionNotAllowed` (present); a missing one `errSecItemNotFound`.
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
        var query = itemQuery(account: account, accessGroup: accessGroup)
        query[kSecAttrAccessControl as String] = access
        query[kSecValueData as String] = data
        return SecItemAdd(query as CFDictionary, nil)
    }
}
