import Foundation
import os
import Security
import Testing
@testable import VaultData

/// Records the probe's `SecItem` calls and answers with scripted statuses. Never touches the
/// real keychain.
private final class RecordingKeychainCalls: KeychainItemCalling {
    struct Call: Sendable {
        let kind: Kind
        let service: String?
        let account: String?
        let accessGroup: String?
        let usesDataProtectionKeychain: Bool
        let isSynchronizable: Bool?
        let hasAccessControl: Bool
        let hasAccessibleAttribute: Bool
        let valueCount: Int?
        let asksForData: Bool
        let asksForAttributes: Bool
    }

    enum Kind: Sendable {
        case add
        case delete
    }

    private struct State {
        var calls: [Call] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let addStatus: OSStatus
    private let deleteStatus: OSStatus

    init(addStatus: OSStatus = errSecSuccess, deleteStatus: OSStatus = errSecSuccess) {
        self.addStatus = addStatus
        self.deleteStatus = deleteStatus
    }

    var calls: [Call] {
        state.withLock { $0.calls }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        record(.add, attributes)
        return addStatus
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        record(.delete, query)
        return deleteStatus
    }

    private func record(_ kind: Kind, _ query: [String: Any]) {
        let call = Call(
            kind: kind,
            service: query[kSecAttrService as String] as? String,
            account: query[kSecAttrAccount as String] as? String,
            accessGroup: query[kSecAttrAccessGroup as String] as? String,
            usesDataProtectionKeychain: query[kSecUseDataProtectionKeychain as String] as? Bool == true,
            isSynchronizable: query[kSecAttrSynchronizable as String] as? Bool,
            hasAccessControl: query[kSecAttrAccessControl as String] != nil,
            hasAccessibleAttribute: query[kSecAttrAccessible as String] != nil,
            valueCount: (query[kSecValueData as String] as? Data)?.count,
            asksForData: query[kSecReturnData as String] != nil,
            asksForAttributes: query[kSecReturnAttributes as String] != nil
        )
        state.withLock { $0.calls.append(call) }
    }
}

@Suite("KeychainProbe (--diagnose)")
struct KeychainProbeTests {
    private static let group = FakeBuildCapabilities.defaultAccessGroup

    @Test func addsAndDeletesOneItemWithTheTouchIDAttributes() throws {
        let calls = RecordingKeychainCalls()
        let result = KeychainProbe(calls: calls).run(accessGroup: Self.group)

        #expect(result == KeychainProbeResultModel(addStatus: errSecSuccess, deleteStatus: errSecSuccess))
        #expect(result.passed)
        let recorded = calls.calls
        try #require(recorded.count == 3)
        let cleanup = recorded[0]
        let add = recorded[1]
        let delete = recorded[2]
        #expect(cleanup.kind == .delete)
        #expect(add.kind == .add)
        #expect(delete.kind == .delete)

        #expect(add.service == "io.fractalx.fxvault.diagnose")
        #expect(add.service != BiometricKeyAccount.service)
        #expect(add.accessGroup == Self.group)
        #expect(add.usesDataProtectionKeychain)
        #expect(add.isSynchronizable == false)
        #expect(add.hasAccessControl)
        #expect(!add.hasAccessibleAttribute)
        #expect(add.valueCount == KeychainProbe.payloadBytes)
        #expect(!add.asksForData)
        #expect(add.account?.hasPrefix(KeychainProbe.accountPrefix) == true)

        // The delete targets exactly the item that was added, and never asks for data.
        #expect(delete.service == add.service)
        #expect(delete.account == add.account)
        #expect(delete.accessGroup == Self.group)
        #expect(delete.usesDataProtectionKeychain)
        #expect(!delete.asksForData)
        #expect(!delete.asksForAttributes)
        #expect(delete.valueCount == nil)
    }

    @Test func firstRemovesLeftoversOfEarlierRunsInTheProbeServiceOnly() throws {
        let calls = RecordingKeychainCalls()
        _ = KeychainProbe(calls: calls).run(accessGroup: Self.group)
        let cleanup = try #require(calls.calls.first)
        #expect(cleanup.kind == .delete)
        #expect(cleanup.service == KeychainProbe.service)
        #expect(cleanup.service != BiometricKeyAccount.service)
        // No account: every probe item of the group, whatever run left it.
        #expect(cleanup.account == nil)
        #expect(cleanup.accessGroup == Self.group)
        #expect(cleanup.usesDataProtectionKeychain)
        #expect(!cleanup.asksForData)
        #expect(!cleanup.asksForAttributes)
    }

    @Test func alwaysDeletesEvenWhenTheAddFails() {
        let calls = RecordingKeychainCalls(addStatus: errSecMissingEntitlement, deleteStatus: errSecItemNotFound)
        let result = KeychainProbe(calls: calls).run(accessGroup: Self.group)
        #expect(result.addStatus == errSecMissingEntitlement)
        #expect(result.deleteStatus == errSecItemNotFound)
        #expect(!result.passed)
        #expect(calls.calls.map(\.kind) == [.delete, .add, .delete])
    }

    @Test func everyRunUsesANewRandomAccount() throws {
        let calls = RecordingKeychainCalls()
        let probe = KeychainProbe(calls: calls)
        _ = probe.run(accessGroup: Self.group)
        _ = probe.run(accessGroup: Self.group)
        let accounts = calls.calls.filter { $0.kind == .add }.compactMap(\.account)
        try #require(accounts.count == 2)
        #expect(accounts[0] != accounts[1])
    }

    @Test func failedDeleteIsReported() {
        let result = KeychainProbe(calls: RecordingKeychainCalls(deleteStatus: errSecInteractionNotAllowed))
            .run(accessGroup: Self.group)
        #expect(result.addStatus == errSecSuccess)
        #expect(result.deleteStatus == errSecInteractionNotAllowed)
        #expect(!result.passed)
    }

    @Test(arguments: [
        (errSecSuccess, "errSecSuccess"),
        (errSecMissingEntitlement, "errSecMissingEntitlement"),
        (errSecItemNotFound, "errSecItemNotFound"),
        (errSecDuplicateItem, "errSecDuplicateItem"),
        (errSecAuthFailed, "errSecAuthFailed"),
        (errSecInteractionNotAllowed, "errSecInteractionNotAllowed"),
        (errSecParam, "errSecParam"),
        (errSecUserCanceled, "errSecUserCanceled"),
        (errSecNotAvailable, "errSecNotAvailable"),
    ])
    func statusNames(_ status: OSStatus, _ name: String) {
        #expect(KeychainProbe.statusName(status) == name)
    }

    @Test func unknownStatusHasNoName() {
        #expect(KeychainProbe.statusName(OSStatus(-1)) == nil)
    }
}
