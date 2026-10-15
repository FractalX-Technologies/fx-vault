import Foundation
import GitHubKit
import Security

/// What `FX Vault --diagnose` prints (v0.1.1): build facts, Touch ID availability, a keychain
/// probe and, since v0.3.1, the GitHub CLI (`gh`: `GHDiagnosticsModel`). It never holds a secret:
/// the probe value is random and never read back, and the gh section holds paths, versions,
/// variable names and account logins only.
///
/// JSON (keys sorted; absent values are `null`, never omitted):
/// ```json
/// {
///   "biometryAvailable": true,
///   "biometryUnavailableReason": null,
///   "build": "2",
///   "gh": { "accounts": [...], "candidates": [...], "chosenPath": "/opt/homebrew/bin/gh",
///           "result": "ready", "shell": {...}, ... },
///   "isSignedWithAccessGroup": true,
///   "keychainAccessGroup": "<team id>.io.fractalx.fxvault",
///   "probe": {
///     "add": 0, "addName": "errSecSuccess",
///     "delete": 0, "deleteName": "errSecSuccess",
///     "passed": true, "skipped": false, "skippedReason": null
///   },
///   "version": "0.1.1"
/// }
/// ```
nonisolated struct DiagnosticReportModel: Encodable, Equatable {
    let version: String
    let build: String
    let isSignedWithAccessGroup: Bool
    let keychainAccessGroup: String?
    let biometryAvailable: Bool
    /// `BiometryUnavailableReason.rawValue` (for example `notEnrolled`), or nil when available.
    let biometryUnavailableReason: String?
    let probe: DiagnosticProbeModel
    /// The GitHub CLI: shell probe, every gh candidate, the accounts gh lists (v0.3.1).
    let gh: GHDiagnosticsModel

    private enum CodingKeys: String, CodingKey {
        case version
        case build
        case isSignedWithAccessGroup
        case keychainAccessGroup
        case biometryAvailable
        case biometryUnavailableReason
        case probe
        case gh
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(build, forKey: .build)
        try container.encode(isSignedWithAccessGroup, forKey: .isSignedWithAccessGroup)
        try container.encode(keychainAccessGroup, forKey: .keychainAccessGroup)
        try container.encode(biometryAvailable, forKey: .biometryAvailable)
        try container.encode(biometryUnavailableReason, forKey: .biometryUnavailableReason)
        try container.encode(probe, forKey: .probe)
        try container.encode(gh, forKey: .gh)
    }

    /// Pretty-printed JSON with sorted keys and unescaped slashes, plus a trailing newline.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(contentsOf: Self.newline)
        return data
    }

    private static let newline = Data("\n".utf8)
}

/// The keychain probe part of the report: the raw `OSStatus` of the add and the delete, their
/// Security constant names when known, or why the probe was skipped.
nonisolated struct DiagnosticProbeModel: Encodable, Equatable {
    /// Why the probe did not run.
    enum SkipReason: String, Encodable {
        /// Ad-hoc build: no keychain access group entitlement, so nothing is added.
        case unsignedBuild
        /// Security could not build the `.biometryCurrentSet` access control (no add attempted).
        case accessControlUnavailable
    }

    let add: Int32?
    let addName: String?
    let delete: Int32?
    let deleteName: String?
    let skippedReason: SkipReason?

    var skipped: Bool {
        skippedReason != nil
    }

    /// The add and the delete both returned `errSecSuccess`.
    var passed: Bool {
        add == errSecSuccess && delete == errSecSuccess
    }

    static func skipped(_ reason: SkipReason, deleteStatus: Int32? = nil, deleteName: String? = nil) -> Self {
        DiagnosticProbeModel(add: nil, addName: nil, delete: deleteStatus, deleteName: deleteName, skippedReason: reason)
    }

    private enum CodingKeys: String, CodingKey {
        case add
        case addName
        case delete
        case deleteName
        case passed
        case skipped
        case skippedReason
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(add, forKey: .add)
        try container.encode(addName, forKey: .addName)
        try container.encode(delete, forKey: .delete)
        try container.encode(deleteName, forKey: .deleteName)
        try container.encode(passed, forKey: .passed)
        try container.encode(skipped, forKey: .skipped)
        try container.encode(skippedReason, forKey: .skippedReason)
    }
}
