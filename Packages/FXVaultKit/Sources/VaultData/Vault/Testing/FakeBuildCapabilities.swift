import Foundation
import os
import VaultCore

/// A scriptable ``BuildCapabilitiesProviding`` for tests and previews (§12.2).
///
/// Defaults describe a signed build on a Mac with Touch ID ready: an access group, no
/// unavailability, a fixed state hash and a fixed boot session. Change them to simulate an
/// ad-hoc build, a restart (``bootSession``) or an enrollment change (``stateHash``).
public final class FakeBuildCapabilities: BuildCapabilitiesProviding {
    /// The access group of the default signed build.
    public static let defaultAccessGroup = "TEAMID0000.io.fractalx.fxvault"
    /// The state hash of the default enrollment.
    public static let defaultStateHash = Data("enrollment-a".utf8)
    /// The boot session of the default run.
    public static let defaultBootSession = "00000000-0000-4000-8000-00000000b001"

    private struct State: Sendable {
        var accessGroup: String? = FakeBuildCapabilities.defaultAccessGroup
        var unavailableReason: BiometryUnavailableReason?
        var stateHash: Data? = FakeBuildCapabilities.defaultStateHash
        var bootSession: String? = FakeBuildCapabilities.defaultBootSession
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// The access group; nil simulates an ad-hoc build.
    public var accessGroup: String? {
        get { state.withLock { $0.accessGroup } }
        set { state.withLock { $0.accessGroup = newValue } }
    }

    /// Why Touch ID is unavailable; nil means available.
    public var unavailableReason: BiometryUnavailableReason? {
        get { state.withLock { $0.unavailableReason } }
        set { state.withLock { $0.unavailableReason = newValue } }
    }

    /// The enrollment fingerprint; change it to simulate an enrollment change.
    public var stateHash: Data? {
        get { state.withLock { $0.stateHash } }
        set { state.withLock { $0.stateHash = newValue } }
    }

    /// The boot session; change it to simulate a restart.
    public var bootSession: String? {
        get { state.withLock { $0.bootSession } }
        set { state.withLock { $0.bootSession = newValue } }
    }

    // MARK: - BuildCapabilitiesProviding

    public var keychainAccessGroup: String? {
        accessGroup
    }

    public func biometryUnavailableReason() -> BiometryUnavailableReason? {
        unavailableReason
    }

    public func biometryStateHash() -> Data? {
        stateHash
    }

    public func bootSessionID() -> String? {
        bootSession
    }
}
