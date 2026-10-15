import Foundation
import Observation
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
        static let recoveryKeyConfirmationPending = "preferences.recoveryKeyConfirmationPending"
        static let touchIDOfferAnswered = "preferences.touchIDOfferAnswered"
        static let nearbyDisplayName = "preferences.nearbyDisplayName"
    }

    /// Auto-lock choices offered in Preferences, in minutes (§5.7).
    static let autoLockOptions = Timeouts.autoLockOptionMinutes

    @ObservationIgnored private let store: any PreferencesStore

    init(store: any PreferencesStore) {
        self.store = store
        autoLockMinutes = Self.validatedAutoLockMinutes(store.integer(forKey: Key.autoLockMinutes))
        cloneFolderPath = store.string(forKey: Key.cloneFolderPath)
        ghPathOverride = Self.normalizedPath(store.string(forKey: Key.ghPathOverride))
        isRecoveryKeyConfirmationPending = store.bool(forKey: Key.recoveryKeyConfirmationPending)
        hasAnsweredTouchIDOffer = store.bool(forKey: Key.touchIDOfferAnswered)
        nearbyDisplayName = store.string(forKey: Key.nearbyDisplayName)
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

    /// The name nearby Macs see while Nearby Chat is open (v0.2.0), as typed, or nil for the
    /// macOS user's full name (a blank name is nil). Readers trim it (``nearbyName``). Sent in
    /// cleartext on the local network and unverified for the receiver (SECURITY-MODEL.md).
    var nearbyDisplayName: String? {
        didSet {
            if let name = nearbyDisplayName, Self.normalizedName(name) == nil {
                nearbyDisplayName = nil
                return
            }
            store.set(nearbyDisplayName, forKey: Key.nearbyDisplayName)
        }
    }

    /// ``nearbyDisplayName`` trimmed, or nil.
    var nearbyName: String? {
        Self.normalizedName(nearbyDisplayName)
    }

    // MARK: - Validation

    static func validatedAutoLockMinutes(_ minutes: Int?) -> Int {
        guard let minutes, autoLockOptions.contains(minutes) else { return Timeouts.autoLockDefaultMinutes }
        return minutes
    }

    private static func normalizedName(_ name: String?) -> String? {
        normalizedPath(name)
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
