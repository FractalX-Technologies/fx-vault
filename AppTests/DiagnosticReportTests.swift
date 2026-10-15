import Foundation
import GitHubKit
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
        "biometryAvailable", "biometryUnavailableReason", "probe", "gh",
    ]

    /// A `GH_CONFIG_DIR` value the shell probe captured: the report names the variable only.
    private static let configDirValue = "/Users/user-a/.config/gh-private-marker"

    /// A gh section: the shell's Homebrew gh in use, one missing candidate, one usable managed
    /// user account and one account FX Vault cannot use (synthetic names).
    static let sampleGH: GHDiagnosticsModel = {
        let installation = GHInstallationModel(
            path: "/opt/homebrew/bin/gh",
            resolvedPath: "/opt/homebrew/Cellar/gh/2.102.0/bin/gh",
            version: GHVersion(major: 2, minor: 102, patch: 0)
        )
        return GHDiagnosticsModel(
            shell: ShellEnvironmentModel(
                path: "/opt/homebrew/bin:/usr/bin",
                ghConfigDir: configDirValue,
                ghPath: installation.path,
                setVariables: [.ghToken, .ghConfigDir],
                probeMode: .interactive,
                shellPath: "/bin/zsh"
            ),
            overridePath: nil,
            trustedBinary: nil,
            trustedOwnerName: nil,
            report: GHLocatorReportModel(
                candidates: [
                    GHCandidateReportModel(
                        path: installation.path,
                        source: .shell,
                        resolvedPath: installation.resolvedPath,
                        rejection: nil,
                        version: installation.version
                    ),
                    GHCandidateReportModel(path: "/opt/local/bin/gh", source: .fallback, resolvedPath: nil, rejection: .notFound),
                ],
                decisiveIndex: 0,
                outcome: .success(installation)
            ),
            listing: GHAccountListingModel(
                accounts: [GHAccountStatusModel(
                    login: "user1_acme",
                    isActive: true,
                    state: .ok,
                    scopes: .ok,
                    scopeList: ["repo", "read:org"],
                    gitProtocol: "https",
                    tokenSource: "keyring"
                )],
                unusable: [GHUnusableAccountModel(displayLogin: "_user2", violation: .invalidFirstCharacter, isActive: false)]
            ),
            accountsError: nil
        )
    }()
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
            probe: KeychainProbe(calls: calls),
            gh: Self.sampleGH
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
            probe: KeychainProbe(calls: calls),
            gh: Self.sampleGH
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
            probe: KeychainProbe(calls: ScriptedKeychainCalls(add: status, delete: errSecItemNotFound)),
            gh: Self.sampleGH
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
            probe: KeychainProbe(calls: ScriptedKeychainCalls(add: OSStatus(-1))),
            gh: Self.sampleGH
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
            probe: KeychainProbe(calls: calls),
            gh: Self.sampleGH
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
            probe: KeychainProbe(calls: ScriptedKeychainCalls()),
            gh: Self.sampleGH
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

    @Test func theGHSectionIsInTheReportWithExplicitNulls() throws {
        let report = DiagnosticReporter.makeReport(
            infoDictionary: Self.info,
            capabilities: FakeBuildCapabilities(),
            probe: KeychainProbe(calls: ScriptedKeychainCalls()),
            gh: Self.sampleGH
        )
        let object = try json(report)
        let gh = try #require(object["gh"] as? [String: Any])
        #expect(Set(gh.keys) == [
            "shell", "overridePath", "trustedBinary", "candidates", "chosenPath", "result",
            "accountsChecked", "accounts", "unusableAccounts", "accountsError",
        ])
        #expect(gh["result"] as? String == "ready")
        #expect(gh["chosenPath"] as? String == "/opt/homebrew/bin/gh")
        #expect(gh["overridePath"] is NSNull)
        #expect(gh["trustedBinary"] is NSNull)
        let shell = try #require(gh["shell"] as? [String: Any])
        #expect(shell["probeMode"] as? String == "interactive")
        #expect(shell["ghPath"] as? String == "/opt/homebrew/bin/gh")
        #expect(shell["variablesSet"] as? [String] == ["GH_CONFIG_DIR", "GH_TOKEN"])
        let accounts = try #require(gh["accounts"] as? [[String: Any]])
        #expect(accounts.first?["login"] as? String == "user1_acme")
        #expect(accounts.first?["tokenSource"] as? String == "keyring")
        #expect(accounts.first?["scopes"] as? String == "ok")
        let unusable = try #require(gh["unusableAccounts"] as? [[String: Any]])
        #expect(unusable.first?["reason"] as? String == "invalidFirstCharacter")
        let text = try #require(String(data: try report.jsonData(), encoding: .utf8))
        #expect(!text.contains(Self.configDirValue), "variables are named, never valued")
    }

    @Test func theCopiedTextReportIsStableAndValueFree() {
        let text = GHDiagnosticsTextRenderer.render(Self.sampleGH, version: "0.3.1", build: "7")
        #expect(text == """
        FX Vault GitHub CLI diagnostics: FX Vault 0.3.1 (7)
        Paths, versions, variable names and account names only: no tokens, secrets or variable values.

        Result: ready
        Chosen gh: /opt/homebrew/bin/gh
        gh path override: none
        Trusted gh: none

        Shell: /bin/zsh (probe: interactive)
        Shell gh (command -v gh): /opt/homebrew/bin/gh
        Shell variables set: GH_CONFIG_DIR, GH_TOKEN

        Candidates:
        * /opt/homebrew/bin/gh [shell] -> /opt/homebrew/Cellar/gh/2.102.0/bin/gh: accepted (gh 2.102.0) [chosen]
        - not found: /opt/local/bin/gh

        Accounts (github.com): 1
        - user1_acme: state ok, active, token source keyring, scopes ok
        Accounts FX Vault cannot use:
        - _user2: invalidFirstCharacter

        """)
        #expect(!text.contains(Self.configDirValue))
    }

    @Test func aFailedDetectionStillRendersEverySection() {
        let model = GHDiagnosticsModel.unavailable(.launchFailed, overridePath: "/Users/user-a/bin/gh", trustedBinary: nil)
        let text = GHDiagnosticsTextRenderer.render(model, version: "0.3.1", build: "7")
        #expect(text.contains("Result: launchFailed"))
        #expect(text.contains("gh path override: /Users/user-a/bin/gh"))
        #expect(text.contains("Shell: none (probe: failed)"))
        #expect(text.contains("Accounts: not checked (no usable gh)"))
    }

    @Test func reportNeverContainsTheProbeValueOrAccount() throws {
        let report = DiagnosticReporter.makeReport(
            infoDictionary: Self.info,
            capabilities: FakeBuildCapabilities(),
            probe: KeychainProbe(calls: ScriptedKeychainCalls()),
            gh: Self.sampleGH
        )
        let text = try #require(String(data: try report.jsonData(), encoding: .utf8))
        #expect(!text.contains("probe-"))
        #expect(!text.contains(KeychainProbe.service))
    }
}
