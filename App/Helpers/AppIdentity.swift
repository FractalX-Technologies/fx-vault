import Foundation

/// Which app this build is (ARCHITECTURE.md "Build identities").
///
/// - Release is **FX Vault** (`io.fractalx.fxvault`) and uses the `FX Vault` vault folder.
/// - Debug is the separate app **FX Vault Dev** (`io.fractalx.fxvault.dev`, set per
///   configuration in `project.yml`) and uses the `FX Vault Dev` vault folder, so Spotlight,
///   the Dock and Finder never mistake a development build for the real app.
///
/// Identifiers that name shared formats or stored items stay constant in both builds: the
/// logging subsystem, the Touch ID keychain services (already split by vault flavor), the
/// keychain access group, the `.fxvault` UTType and the share schema.
nonisolated enum AppIdentity {
    /// The release bundle identifier.
    static let releaseBundleIdentifier = "io.fractalx.fxvault"

    /// This build's bundle identifier (`io.fractalx.fxvault.dev` in Debug).
    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? releaseBundleIdentifier
    }

    /// True in Debug builds, which open the `FX Vault Dev` vault (the same `DEBUG` condition
    /// that picks the vault folder in VaultStore).
    static var isDevelopmentBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// The main window title: "FX Vault", or "FX Vault Dev" in Debug.
    static var windowTitle: String {
        isDevelopmentBuild
            ? String(localized: "app.window.title.dev", defaultValue: "FX Vault Dev")
            : String(localized: "app.window.title", defaultValue: "FX Vault")
    }
}
