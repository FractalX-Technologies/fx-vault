import Darwin
import Foundation
import LocalAuthentication
import Security
import VaultCore

/// What this build and this Mac allow for Touch ID, and the facts the password rules need
/// (D14, D15, §5.5). ``BuildCapabilities`` is the live implementation; tests inject
/// ``FakeBuildCapabilities``.
public protocol BuildCapabilitiesProviding: Sendable {
    /// The keychain access group from the signed `keychain-access-groups` entitlement, or nil in
    /// ad-hoc builds (no Touch ID: the toggle is disabled with a note).
    var keychainAccessGroup: String? { get }

    /// Why biometric authentication cannot run on this Mac right now, or nil when it can.
    func biometryUnavailableReason() -> BiometryUnavailableReason?

    /// The current biometric enrollment fingerprint (`domainState.biometry.stateHash` on
    /// macOS 15+, `evaluatedPolicyDomainState` on 14), or nil when Touch ID is unavailable. It
    /// changes whenever a fingerprint is added or removed.
    func biometryStateHash() -> Data?

    /// `kern.bootsessionuuid`: changes on every restart. Nil if it cannot be read, which the
    /// restart rule treats as a restart (fail closed).
    func bootSessionID() -> String?
}

extension BuildCapabilitiesProviding {
    /// True in Developer ID-signed builds with the embedded profile (§5.5).
    public var hasKeychainAccessGroup: Bool {
        keychainAccessGroup != nil
    }
}

/// The live ``BuildCapabilitiesProviding``: a SecTask entitlement check (D15), `LAContext`
/// availability and domain state, and `sysctl kern.bootsessionuuid`.
public struct BuildCapabilities: BuildCapabilitiesProviding {
    public let keychainAccessGroup: String?

    /// Reads the entitlement once.
    public init() {
        keychainAccessGroup = Self.entitledAccessGroup()
    }

    public func biometryUnavailableReason() -> BiometryUnavailableReason? {
        BiometricAuthManager.evaluateAvailability()
    }

    public func biometryStateHash() -> Data? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return nil
        }
        if #available(macOS 15.0, *) {
            return context.domainState.biometry.stateHash
        }
        return context.evaluatedPolicyDomainState
    }

    public func bootSessionID() -> String? {
        var size = 0
        guard sysctlbyname(Self.bootSessionSysctl, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(Self.bootSessionSysctl, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(decoding: buffer.prefix(size).prefix { $0 != 0 }, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    // MARK: - Internal

    /// The `sysctl` name of the boot session UUID.
    static let bootSessionSysctl = "kern.bootsessionuuid"
    /// The entitlement that carries the keychain access groups (D15).
    static let accessGroupsEntitlement = "keychain-access-groups"
    /// The App ID suffix of FX Vault's own group (`<team>.io.fractalx.fxvault`).
    static let accessGroupSuffix = "io.fractalx.fxvault"

    /// Picks FX Vault's group from the entitlement value: the entry ending in
    /// ``accessGroupSuffix``, else the first entry.
    static func accessGroup(fromEntitlement value: Any?) -> String? {
        guard let groups = value as? [String], !groups.isEmpty else { return nil }
        return groups.first { $0.hasSuffix(accessGroupSuffix) } ?? groups.first
    }

    // MARK: - Private

    private static func entitledAccessGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else { return nil }
        let value = SecTaskCopyValueForEntitlement(task, accessGroupsEntitlement as CFString, nil)
        return accessGroup(fromEntitlement: value)
    }
}
