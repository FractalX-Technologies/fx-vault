import Foundation
import GitHubKit
import VaultData

/// Builds the `--diagnose` report from the build's capabilities, a keychain probe, the bundle's
/// version keys and the gh diagnostics. Pure apart from what the injected probe does; tests pass
/// `FakeBuildCapabilities`, a fake probe and a fixed gh section.
nonisolated enum DiagnosticReporter {
    /// Info.plist keys of the version and build numbers.
    static let versionKey = "CFBundleShortVersionString"
    static let buildKey = "CFBundleVersion"
    /// Shown when a version key is missing.
    static let unknownValue = "unknown"

    static func makeReport(
        infoDictionary: [String: Any]?,
        capabilities: any BuildCapabilitiesProviding,
        probe: any KeychainProbing,
        gh: GHDiagnosticsModel
    ) -> DiagnosticReportModel {
        let accessGroup = capabilities.keychainAccessGroup
        let unavailableReason = capabilities.biometryUnavailableReason()
        let identity = versionAndBuild(infoDictionary: infoDictionary)
        return DiagnosticReportModel(
            version: identity.version,
            build: identity.build,
            isSignedWithAccessGroup: accessGroup != nil,
            keychainAccessGroup: accessGroup,
            biometryAvailable: unavailableReason == nil,
            biometryUnavailableReason: unavailableReason?.rawValue,
            probe: probeModel(accessGroup: accessGroup, probe: probe),
            gh: gh
        )
    }

    /// The version and build numbers of the bundle (also the first line of Copy Diagnostics).
    static func versionAndBuild(infoDictionary: [String: Any]?) -> (version: String, build: String) {
        (
            infoDictionary?[versionKey] as? String ?? unknownValue,
            infoDictionary?[buildKey] as? String ?? unknownValue
        )
    }

    /// Unsigned builds skip the probe: without the entitlement the add can only fail, and the
    /// report already says why Touch ID is off.
    static func probeModel(accessGroup: String?, probe: any KeychainProbing) -> DiagnosticProbeModel {
        guard let accessGroup else { return .skipped(.unsignedBuild) }
        let result = probe.run(accessGroup: accessGroup)
        guard let addStatus = result.addStatus else {
            return .skipped(
                .accessControlUnavailable,
                deleteStatus: result.deleteStatus,
                deleteName: KeychainProbe.statusName(result.deleteStatus)
            )
        }
        return DiagnosticProbeModel(
            add: addStatus,
            addName: KeychainProbe.statusName(addStatus),
            delete: result.deleteStatus,
            deleteName: KeychainProbe.statusName(result.deleteStatus),
            skippedReason: nil
        )
    }
}
