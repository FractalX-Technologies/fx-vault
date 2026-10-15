import Foundation
import Security

/// The two `SecItem` calls ``KeychainProbe`` makes. There is deliberately no read: the probe can
/// never show a Touch ID prompt or return item data. ``SystemKeychainItemCalls`` is the live
/// implementation; tests record the attributes with a fake.
public protocol KeychainItemCalling: Sendable {
    /// `SecItemAdd(attributes, nil)`.
    func add(_ attributes: [String: Any]) -> OSStatus
    /// `SecItemDelete(query)`.
    func delete(_ query: [String: Any]) -> OSStatus
}

/// The live ``KeychainItemCalling`` over Security.framework.
public struct SystemKeychainItemCalls: KeychainItemCalling {
    public init() {}

    public func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// Checks whether this build can create Touch ID keychain items, without a prompt (`--diagnose`).
public protocol KeychainProbing: Sendable {
    /// Adds and deletes one probe item in `accessGroup`.
    func run(accessGroup: String) -> KeychainProbeResultModel
}

/// What one probe run did. `addStatus` is nil when the access control could not be built and
/// no add was attempted (the delete still runs).
public struct KeychainProbeResultModel: Sendable, Hashable {
    public let addStatus: OSStatus?
    public let deleteStatus: OSStatus

    public init(addStatus: OSStatus?, deleteStatus: OSStatus) {
        self.addStatus = addStatus
        self.deleteStatus = deleteStatus
    }

    /// True when the add succeeded and the item was deleted again: a real Touch ID item would
    /// be stored the same way.
    public var passed: Bool {
        addStatus == errSecSuccess && deleteStatus == errSecSuccess
    }
}

/// Adds and deletes one throwaway item with **exactly** the attributes of a Touch ID DEK item
/// (``KeychainManager/addQuery(data:account:accessGroup:access:service:)``: data-protection
/// keychain, the entitled access group, `WhenPasscodeSetThisDeviceOnly` + `.biometryCurrentSet`,
/// not synchronizable), under its own service so it can never touch a vault's item.
///
/// - The account is random and the value is 16 random bytes (zeroed after the add), so nothing
///   secret is ever stored or printed.
/// - It never reads the item (no prompt) and always deletes it, even when the add failed.
/// - It first deletes every item of the probe service in the group, so an item left by an
///   earlier run (a failed delete, or the process killed between add and delete) is removed.
public struct KeychainProbe: KeychainProbing {
    /// The keychain service of probe items.
    public static let service = "io.fractalx.fxvault.diagnose"
    /// Prefix of the random probe account.
    static let accountPrefix = "probe-"
    /// Size of the random probe value.
    static let payloadBytes = 16

    private let calls: any KeychainItemCalling

    public init(calls: any KeychainItemCalling = SystemKeychainItemCalls()) {
        self.calls = calls
    }

    public func run(accessGroup: String) -> KeychainProbeResultModel {
        // Leftovers of earlier runs; usually errSecItemNotFound, which is fine.
        _ = calls.delete(KeychainManager.itemQuery(account: nil, accessGroup: accessGroup, service: Self.service))
        let account = Self.accountPrefix + UUID().uuidString.lowercased()
        let addStatus = KeychainManager.biometricAccessControl().map { access in
            add(account: account, accessGroup: accessGroup, access: access)
        }
        let deleteQuery = KeychainManager.itemQuery(account: account, accessGroup: accessGroup, service: Self.service)
        let deleteStatus = calls.delete(deleteQuery)
        return KeychainProbeResultModel(addStatus: addStatus, deleteStatus: deleteStatus)
    }

    /// Runs the add in its own scope so the attributes (and their reference to the value) are
    /// gone before the value is zeroed.
    private func add(account: String, accessGroup: String, access: SecAccessControl) -> OSStatus {
        var payload = Data((0..<Self.payloadBytes).map { _ in UInt8.random(in: .min ... .max) })
        defer { payload.resetBytes(in: payload.startIndex..<payload.endIndex) }
        let attributes = KeychainManager.addQuery(
            data: payload,
            account: account,
            accessGroup: accessGroup,
            access: access,
            service: Self.service
        )
        return calls.add(attributes)
    }

    // MARK: - Status names

    /// The Security constant name of a status the Touch ID paths can return, or nil for any
    /// other code. Used by `--diagnose` next to the raw number.
    public static func statusName(_ status: OSStatus) -> String? {
        knownStatuses[status]
    }

    private static let knownStatuses: [OSStatus: String] = [
        errSecSuccess: "errSecSuccess",
        errSecParam: "errSecParam",
        errSecAllocate: "errSecAllocate",
        errSecUserCanceled: "errSecUserCanceled",
        errSecNotAvailable: "errSecNotAvailable",
        errSecAuthFailed: "errSecAuthFailed",
        errSecNoSuchKeychain: "errSecNoSuchKeychain",
        errSecDuplicateItem: "errSecDuplicateItem",
        errSecItemNotFound: "errSecItemNotFound",
        errSecInteractionNotAllowed: "errSecInteractionNotAllowed",
        errSecDecode: "errSecDecode",
        errSecNoAccessForItem: "errSecNoAccessForItem",
        errSecMissingEntitlement: "errSecMissingEntitlement",
    ]
}
