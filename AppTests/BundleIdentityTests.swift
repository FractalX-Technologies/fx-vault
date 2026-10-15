import AppKit
import Foundation
import Testing
@testable import FXVault

/// v0.1.2: Debug builds are the separate app "FX Vault Dev" (`io.fractalx.fxvault.dev`) with
/// their own vault folder; Release stays exactly "FX Vault" (`io.fractalx.fxvault`), which
/// `scripts/release-local.sh` also checks.
@MainActor
@Suite("Build identity")
struct BundleIdentityTests {
    static let releaseBundleID = "io.fractalx.fxvault"
    static let debugBundleID = "io.fractalx.fxvault.dev"

    // MARK: - The running (Debug) host app

    @Test func debugHostIsFXVaultDev() {
        #expect(AppIdentity.isDevelopmentBuild)
        #expect(Bundle.main.bundleIdentifier == Self.debugBundleID)
        #expect(AppIdentity.bundleIdentifier == Self.debugBundleID)
        #expect(AppIdentity.releaseBundleIdentifier == Self.releaseBundleID)
        // object(forInfoDictionaryKey:) returns the localized value, so this also catches a
        // name coming back into InfoPlist.xcstrings.
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "FX Vault Dev")
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == "FX Vault Dev")
        #expect(AppIdentity.windowTitle == "FX Vault Dev")
    }

    @Test func debugHostDoesNotClaimShareFiles() throws {
        let types = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        #expect(types.first?["LSHandlerRank"] as? String == "Alternate")
    }

    @Test func clipboardSourceMarkerIsThisBuildsIdentity() {
        #expect(ClipboardManager.Marker.sourceIdentifier == Self.debugBundleID)
        #expect(AppLog.subsystem == Self.releaseBundleID, "one logging subsystem for both builds")
    }

    // MARK: - The generated project (Release unchanged)

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The FXVault target's build settings per configuration, read from the generated
    /// `project.pbxproj` (an old-style property list).
    private static func appBuildSettings() throws -> [String: [String: Any]] {
        let url = repositoryRoot.appendingPathComponent("FXVault.xcodeproj/project.pbxproj")
        let data = try Data(contentsOf: url)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let objects = try #require(plist["objects"] as? [String: [String: Any]])
        let target = try #require(objects.values.first {
            $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == "FXVault"
        })
        let listID = try #require(target["buildConfigurationList"] as? String)
        let configurationIDs = try #require(objects[listID]?["buildConfigurations"] as? [String])
        var settings: [String: [String: Any]] = [:]
        for id in configurationIDs {
            let configuration = try #require(objects[id])
            let name = try #require(configuration["name"] as? String)
            settings[name] = try #require(configuration["buildSettings"] as? [String: Any])
        }
        return settings
    }

    @Test func releaseIdentityIsUnchangedAndDebugIsSeparate() throws {
        let settings = try Self.appBuildSettings()
        let release = try #require(settings["Release"])
        let debug = try #require(settings["Debug"])
        #expect(release["PRODUCT_BUNDLE_IDENTIFIER"] as? String == Self.releaseBundleID)
        #expect(release["FXVAULT_APP_NAME"] as? String == "FX Vault")
        #expect(release["FXVAULT_SHARE_HANDLER_RANK"] as? String == "Owner")
        #expect(debug["PRODUCT_BUNDLE_IDENTIFIER"] as? String == Self.debugBundleID)
        #expect(debug["FXVAULT_APP_NAME"] as? String == "FX Vault Dev")
        #expect(debug["FXVAULT_SHARE_HANDLER_RANK"] as? String == "Alternate")
        #expect(release["PRODUCT_NAME"] as? String == debug["PRODUCT_NAME"] as? String)
    }

    @Test func infoPlistTakesTheNameFromTheBuildSettings() throws {
        let url = Self.repositoryRoot.appendingPathComponent("Config/Info.plist")
        let data = try Data(contentsOf: url)
        let info = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(info["CFBundleIdentifier"] as? String == "$(PRODUCT_BUNDLE_IDENTIFIER)")
        #expect(info["CFBundleName"] as? String == "$(FXVAULT_APP_NAME)")
        #expect(info["CFBundleDisplayName"] as? String == "$(FXVAULT_APP_NAME)")
        let exported = try #require(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        #expect(exported.first?["UTTypeIdentifier"] as? String == "io.fractalx.fxvault.share", "the share type is the same in both builds")
    }

    @Test func infoPlistCatalogDoesNotOverrideTheName() throws {
        let url = Self.repositoryRoot.appendingPathComponent("App/Resources/InfoPlist.xcstrings")
        let catalog = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        #expect(strings["CFBundleName"] == nil)
        #expect(strings["CFBundleDisplayName"] == nil)
    }
}
