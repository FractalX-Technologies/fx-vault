import Foundation
import os
import Security
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// A keychain that answers the probe's add and delete with fixed statuses and counts the calls.
/// Never touches the real keychain.
private final class ScriptedKeychainCalls: KeychainItemCalling {
    private let addStatus: OSStatus
    private let deleteStatus: OSStatus
    private let counts = OSAllocatedUnfairLock(initialState: (adds: 0, deletes: 0))

    init(add: OSStatus = errSecSuccess, delete: OSStatus = errSecSuccess) {
        addStatus = add
        deleteStatus = delete
    }

    var callCount: Int {
        counts.withLock { $0.adds + $0.deletes }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        counts.withLock { $0.adds += 1 }
        return addStatus
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        counts.withLock { $0.deletes += 1 }
        return deleteStatus
    }
}

/// A probe that reports a fixed result (for the access-control failure path).
private struct FixedProbe: KeychainProbing {
    let result: KeychainProbeResultModel

    func run(accessGroup: String) -> KeychainProbeResultModel {
        result
    }
}

@Suite("--diagnose report")
struct DiagnosticReportTests {
    private static let info: [String: String] = ["CFBundleShortVersionString": "0.1.1", "CFBundleVersion": "2"]
    private static let topLevelKeys: Set<String> = [
        "version", "build", "isSignedWithAccessGroup", "keychainAccessGroup",
        "biometryAvailable", "biometryUnavailableReason", "probe",
    ]
    private static let probeKeys: Set<String> = [
        "add", "addName", "delete", "deleteName", "passed", "skipped", "skippedReason",
    ]

    private func json(_ report: DiagnosticReportModel) throws -> [String: Any] {
        let data = try report.jsonData()
        #expect(data.last == UInt8(ascii: "\n"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func signedBuildWithAPassingProbe() throws {
        let calls = ScriptedKeychainCalls()
        let report = DiagnosticReporter.makeReport(
            infoDictionary: Self.info,
            capabilities: FakeBuildCapabilities(),
            probe: KeychainProbe(calls: calls)
        )
        let object = try json(report)
        #expect(Set(object.keys) == Self.topLevelKeys)
        #expect(object["version"] as? String == "0.1.1")
        #expect(object["build"] as? String == "2")
        #expect(object["isSignedWithAccessGroup"] as? Bool == true)
        #expect(object["keychainAccessGroup"] as? String == FakeBuildCapabilities.defaultAccessGroup)
        #expect(object["biometryAvailable"] as? Bool == true)
        #expect(object["biometryUnavailableReason"] is NSNull)

        let probe = try #require(object["probe"] as? [String: Any])
        #expect(Set(probe.keys) == Self.probeKeys)
        #expect(probe["add"] as? Int == 0)
        #expect(probe["addName"] as? String == "errSecSuccess")
        #expect(probe["delete"] as? Int == 0)
        #expect(probe["deleteName"] as? String == "errSecSuccess")
        #expect(probe["passed"] as? Bool == true)
        #expect(probe["skipped"] as? Bool == false)
        #expect(probe["skippedReason"] is NSNull)
        // A leftover cleanup, the add and the delete.
        #expect(calls.callCount == 3)
    }

    @Test func unsignedBuildSkipsTheProbe() throws {
        let capabilities = FakeBuildCapabilities()
        capabilities.accessGroup = nil
        let calls = ScriptedKeychainCalls()
        let report = DiagnosticReporter.makeReport(
            infoDictionary: Self.info,
            capabilities: capabilities,
            probe: KeychainProbe(calls: calls)
        )
        let object = try json(report)
        #expect(Set(object.keys) == Self.topLevelKeys)
        #expect(object["isSignedWithAccessGroup"] as? Bool == false)
        #expect(object["keychainAccessGroup"] is NSNull)
        let probe = try #require(object["probe"] as? [String: Any])
        #expect(Set(probe.keys) == Self.probeKeys)
        #expect(probe["skipped"] as? Bool == true)
        #expect(probe["skippedReason"] as? String == "unsignedBuild")
        #expect(probe["add"] is NSNull)
        #expect(probe["delete"] is NSNull)
        #expect(probe["passed"] as? Bool == false)
        #expect(calls.callCount == 0)
    }

    @Test(arguments: [
        (errSecMissingEntitlement, "errSecMissingEntitlement"),
        (errSecParam, "errSecParam"),
        (errSecNotAvailable, "errSecNotAvailable"),
        (errSecAuthFailed, "errSecAuthFailed"),
    ])
    func failedAddIsReportedWithItsName(_ status: OSStatus, _ name: String) throws {
        let report = DiagnosticReporter.makeReport(
            infoDictionary: Self.info,
            capabilities: FakeBuildCapabilities(),
            probe: KeychainProbe(calls: ScriptedKeychainCalls(add: status, delete: errSecItemNotFound))
        )
        #expect(report.probe.add == status)
        #expect(report.probe.addName == name)
        #expect(report.probe.delete == errSecItemNotFound)
        #expect(report.probe.deleteName == "errSecItemNotFound")
        #expect(!report.probe.passed)
        #expect(!report.probe.skipped)
    }

    @Test func unknownStatusHasANullName() throws {
        let report = DiagnosticReporter.makeReport(
            infoDictionary: Self.info,
            capabilities: FakeBuildCapabilities(),
            probe: KeychainProbe(calls: ScriptedKeychainCalls(add: OSStatus(-1)))
        )
        let probe = try #require(try json(report)["probe"] as? [String: Any])
        #expect(probe["add"] as? Int == -1)
        #expect(probe["addName"] is NSNull)
    }

    @Test func unavailableBiometryIsReportedButTheProbeStillRuns() throws {
        let capabilities = FakeBuildCapabilities()
        capabilities.unavailableReason = .notEnrolled
        let calls = ScriptedKeychainCalls()
        let report = DiagnosticReporter.makeReport(
            infoDictionary: Self.info,
            capabilities: capabilities,
            probe: KeychainProbe(calls: calls)
        )
        let object = try json(report)
        #expect(object["biometryAvailable"] as? Bool == false)
        #expect(object["biometryUnavailableReason"] as? String == "notEnrolled")
        // A leftover cleanup, the add and the delete.
        #expect(calls.callCount == 3)
    }

    @Test func accessControlFailureSkipsTheAddButReportsTheDelete() {
        let probe = DiagnosticReporter.probeModel(
            accessGroup: FakeBuildCapabilities.defaultAccessGroup,
            probe: FixedProbe(result: KeychainProbeResultModel(addStatus: nil, deleteStatus: errSecItemNotFound))
        )
        #expect(probe.skippedReason == .accessControlUnavailable)
        #expect(probe.add == nil)
        #expect(probe.delete == errSecItemNotFound)
        #expect(!probe.passed)
    }

    @Test func missingVersionKeysAreUnknown() {
        let report = DiagnosticReporter.makeReport(
            infoDictionary: nil,
            capabilities: FakeBuildCapabilities(),
            probe: KeychainProbe(calls: ScriptedKeychainCalls())
        )
        #expect(report.version == DiagnosticReporter.unknownValue)
        #expect(report.build == DiagnosticReporter.unknownValue)
    }

    @Test func argumentDetection() {
        #expect(DiagnoseCommand.isRequested(arguments: ["/Applications/FX Vault.app/Contents/MacOS/FXVault", "--diagnose"]))
        #expect(!DiagnoseCommand.isRequested(arguments: ["/Applications/FX Vault.app/Contents/MacOS/FXVault"]))
        #expect(!DiagnoseCommand.isRequested(arguments: ["--diagnose"]))
        #expect(!DiagnoseCommand.isRequested(arguments: ["FXVault", "-NSDocumentRevisionsDebugMode", "YES"]))
    }

    @Test func reportNeverContainsTheProbeValueOrAccount() throws {
        let report = DiagnosticReporter.makeReport(
            infoDictionary: Self.info,
            capabilities: FakeBuildCapabilities(),
            probe: KeychainProbe(calls: ScriptedKeychainCalls())
        )
        let text = try #require(String(data: try report.jsonData(), encoding: .utf8))
        #expect(!text.contains("probe-"))
        #expect(!text.contains(KeychainProbe.service))
    }
}
