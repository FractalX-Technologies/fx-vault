import Foundation

/// What this Mac tells a teammate about itself in a share (§9.3 `sender.displayName`,
/// `producer.version`; §9.4 the nearby display name). The receiver sees the name as
/// unverified, and nearby names travel in cleartext on the local network (SECURITY-MODEL.md).
struct ShareLocalIdentityModel: Equatable {
    /// The sender name in packages and the nearby display name (sanitized by VaultData).
    let displayName: String
    /// `CFBundleShortVersionString`.
    let appVersion: String

    /// The macOS user's full name (falling back to the account name) and the app version.
    static var current: ShareLocalIdentityModel {
        let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        let name = fullName.isEmpty ? NSUserName() : fullName
        let version = Bundle.main.object(forInfoDictionaryKey: versionKey) as? String
        return ShareLocalIdentityModel(displayName: name, appVersion: version ?? unknownVersion)
    }

    private static let versionKey = "CFBundleShortVersionString"
    private static let unknownVersion = "0"
}
