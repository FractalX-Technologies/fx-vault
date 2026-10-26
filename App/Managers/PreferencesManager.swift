import Darwin
import Foundation
import GitHubKit
import Observation
import SharingKit
import VaultCore

/// Key-value storage behind ``PreferencesManager``.
///
/// The live app uses `UserDefaults.standard`; previews and tests use ``InMemoryPreferencesStore``
/// so they never write a property list under `~/Library/Preferences`.
protocol PreferencesStore: AnyObject {
    func integer(forKey key: String) -> Int?
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func set(_ value: Int, forKey key: String)
    func set(_ value: String?, forKey key: String)
    func set(_ value: Bool, forKey key: String)
    func removeValue(forKey key: String)
}

/// ``PreferencesStore`` over `UserDefaults`.
final class UserDefaultsPreferencesStore: PreferencesStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func integer(forKey key: String) -> Int? {
        defaults.object(forKey: key) == nil ? nil : defaults.integer(forKey: key)
    }

    func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func bool(forKey key: String) -> Bool {
        defaults.bool(forKey: key)
    }

    func set(_ value: Int, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func set(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func removeValue(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}

/// A volatile ``PreferencesStore`` for previews and tests.
final class InMemoryPreferencesStore: PreferencesStore {
    private var integers: [String: Int] = [:]
    private var strings: [String: String] = [:]
    private var bools: [String: Bool] = [:]

    func integer(forKey key: String) -> Int? {
        integers[key]
    }

    func string(forKey key: String) -> String? {
        strings[key]
    }

    func bool(forKey key: String) -> Bool {
        bools[key] ?? false
    }

    func set(_ value: Int, forKey key: String) {
        integers[key] = value
    }

    func set(_ value: String?, forKey key: String) {
        strings[key] = value
    }

    func set(_ value: Bool, forKey key: String) {
        bools[key] = value
    }

    func removeValue(forKey key: String) {
        integers[key] = nil
        strings[key] = nil
        bools[key] = nil
    }
}

/// The app's user preferences (Preferences › General and Advanced, §10).
///
/// These settings work in every vault phase because they hold no secrets. Values are validated
/// on read, so a hand-edited defaults file can never set, for example, a zero auto-lock timeout.
@Observable
final class PreferencesManager {
    enum Key {
        static let autoLockMinutes = "preferences.autoLockMinutes"
        static let cloneFolderPath = "preferences.cloneFolderPath"
        static let ghPathOverride = "preferences.ghPathOverride"
        static let trustedGHPath = "preferences.trustedGHPath"
        static let trustedGHOwnerUID = "preferences.trustedGHOwnerUID"
        static let recoveryKeyConfirmationPending = "preferences.recoveryKeyConfirmationPending"
        static let touchIDOfferAnswered = "preferences.touchIDOfferAnswered"
        static let sidebarWidth = "preferences.sidebarWidth"
        /// Settings of the nearby, teammate and shared-space features 1.0 removed.
        static let removed = [
            "preferences.nearbyDisplayName", "preferences.nearbyVisibility",
            "preferences.mutesAllPings", "preferences.remoteSpacePort",
        ]
    }

    /// Auto-lock choices offered in Preferences, in minutes (§5.7).
    static let autoLockOptions = Timeouts.autoLockOptionMinutes

    @ObservationIgnored private let store: any PreferencesStore

    init(store: any PreferencesStore) {
        self.store = store
        autoLockMinutes = Self.validatedAutoLockMinutes(store.integer(forKey: Key.autoLockMinutes))
        cloneFolderPath = store.string(forKey: Key.cloneFolderPath)
        ghPathOverride = Self.normalizedPath(store.string(forKey: Key.ghPathOverride))
        trustedGHBinary = Self.validatedTrustedBinary(
            path: store.string(forKey: Key.trustedGHPath),
            ownerUID: store.integer(forKey: Key.trustedGHOwnerUID)
        )
        isRecoveryKeyConfirmationPending = store.bool(forKey: Key.recoveryKeyConfirmationPending)
        hasAnsweredTouchIDOffer = store.bool(forKey: Key.touchIDOfferAnswered)
        sidebarWidth = Self.validatedSidebarWidth(store.integer(forKey: Key.sidebarWidth))
        // The display name shown to nearby Macs is personal data: don't leave it on disk.
        for key in Key.removed {
            store.removeValue(forKey: key)
        }
    }

    /// The main window's sidebar panel width in points, dragged on its trailing gutter. Always
    /// between `Theme.Layout.sidebarMinWidth` and `sidebarMaxWidth`.
    var sidebarWidth: Int {
        didSet {
            let valid = Self.validatedSidebarWidth(sidebarWidth)
            if valid != sidebarWidth {
                sidebarWidth = valid
                return
            }
            store.set(sidebarWidth, forKey: Key.sidebarWidth)
        }
    }

    static func validatedSidebarWidth(_ width: Int?) -> Int {
        guard let width else { return Int(Theme.Layout.sidebarWidth) }
        return min(max(width, Int(Theme.Layout.sidebarMinWidth)), Int(Theme.Layout.sidebarMaxWidth))
    }

    /// Inactivity auto-lock, in minutes. Always one of ``autoLockOptions``.
    var autoLockMinutes: Int {
        didSet {
            let valid = Self.validatedAutoLockMinutes(autoLockMinutes)
            if valid != autoLockMinutes {
                autoLockMinutes = valid
                return
            }
            store.set(autoLockMinutes, forKey: Key.autoLockMinutes)
        }
    }

    /// The inactivity timeout as a duration.
    var autoLockTimeout: Duration {
        Timeouts.autoLock(minutes: autoLockMinutes)
    }

    /// Absolute path of the folder new repositories are cloned into, or nil until chosen.
    private(set) var cloneFolderPath: String?

    /// The clone folder as a file URL.
    var cloneFolderURL: URL? {
        cloneFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func setCloneFolder(_ url: URL?) {
        let path = url?.standardizedFileURL.path
        cloneFolderPath = path
        store.set(path, forKey: Key.cloneFolderPath)
    }

    /// A user-chosen gh executable path that overrides detection (§5.10), or nil.
    var ghPathOverride: String? {
        didSet {
            let normalized = Self.normalizedPath(ghPathOverride)
            if normalized != ghPathOverride {
                ghPathOverride = normalized
                return
            }
            store.set(ghPathOverride, forKey: Key.ghPathOverride)
        }
    }

    /// The gh the user chose to trust although another (non-root) user owns it (§5.10 consented
    /// trust, v0.3.1): its path and that owner's uid, in UserDefaults. `GHLocator` accepts that
    /// exact path only while the owner is unchanged and nothing is writable by others.
    /// Preferences › Advanced lists it with Revoke. Holds no secret.
    private(set) var trustedGHBinary: GHTrustedBinaryModel?

    /// "Trust This gh" on the setup screen.
    func trustGHBinary(_ binary: GHTrustedBinaryModel) {
        guard let valid = Self.validatedTrustedBinary(path: binary.path, ownerUID: Int(binary.ownerUID)) else { return }
        trustedGHBinary = valid
        store.set(valid.path, forKey: Key.trustedGHPath)
        store.set(Int(valid.ownerUID), forKey: Key.trustedGHOwnerUID)
    }

    /// Revoke (Preferences › Advanced).
    func revokeTrustedGHBinary() {
        trustedGHBinary = nil
        store.set(nil as String?, forKey: Key.trustedGHPath)
        store.set(Self.noOwnerUID, forKey: Key.trustedGHOwnerUID)
    }

    /// True after a vault was created and its recovery key was not yet confirmed (for example,
    /// the vault locked during onboarding). Cleared by a confirmation or a new recovery key.
    var isRecoveryKeyConfirmationPending: Bool {
        didSet {
            store.set(isRecoveryKeyConfirmationPending, forKey: Key.recoveryKeyConfirmationPending)
        }
    }

    /// True once the user answered the one-time "Unlock FX Vault with Touch ID" offer (Enable
    /// or Not Now) or turned Touch ID on or off in Settings, so the offer never comes back.
    var hasAnsweredTouchIDOffer: Bool {
        didSet {
            store.set(hasAnsweredTouchIDOffer, forKey: Key.touchIDOfferAnswered)
        }
    }

    // MARK: - Validation

    static func validatedAutoLockMinutes(_ minutes: Int?) -> Int {
        guard let minutes, autoLockOptions.contains(minutes) else { return Timeouts.autoLockDefaultMinutes }
        return minutes
    }

    /// A uid no trusted gh can have (root never needs consent): written on revoke.
    private static let noOwnerUID = 0

    /// An absolute path and a uid that is neither root nor the current user (they never need
    /// consent); anything else, for example a hand-edited defaults file, is ignored.
    static func validatedTrustedBinary(path: String?, ownerUID: Int?) -> GHTrustedBinaryModel? {
        guard let path = normalizedPath(path), path.hasPrefix("/"),
              let ownerUID, let uid = UInt32(exactly: ownerUID),
              Int(uid) != noOwnerUID, uid != getuid()
        else { return nil }
        return GHTrustedBinaryModel(path: path, ownerUID: uid)
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
