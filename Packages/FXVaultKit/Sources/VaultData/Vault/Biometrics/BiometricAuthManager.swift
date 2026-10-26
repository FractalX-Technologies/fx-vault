import Foundation
import LocalAuthentication
import os
import VaultCore

/// Owns the `LAContext`s FX Vault uses for Touch ID (§5.5).
///
/// - Every keychain read gets a **fresh** context with
///   `touchIDAuthenticationAllowableReuseDuration = 0`, so no earlier authentication is reused.
/// - Prompt strings come from the app (``BiometricPrompt``); this type never builds text.
/// - ``invalidate()`` runs on every lock (Phase A, §5.8): it cancels a prompt still on screen and
///   makes the last context unusable.
/// - Policy is always `.deviceOwnerAuthenticationWithBiometrics`, never
///   `.deviceOwnerAuthentication`, which would accept the macOS login password (§5.6).
public final class BiometricAuthManager: Sendable {
    /// `LAContext` is a thread-safe Objective-C object that the SDK does not mark `Sendable`.
    private final class ContextBox: @unchecked Sendable {
        let context: LAContext

        init(_ context: LAContext) {
            self.context = context
        }
    }

    private let current = OSAllocatedUnfairLock<ContextBox?>(initialState: nil)

    public init() {}

    // MARK: - Contexts

    /// A fresh context for one interactive keychain read. Invalidates the previous one.
    func promptContext(for prompt: BiometricPrompt) -> LAContext {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = Self.noReuse
        context.localizedReason = prompt.reason
        context.localizedFallbackTitle = prompt.fallbackTitle
        context.interactionNotAllowed = false
        let box = ContextBox(context)
        let previous = current.withLock { state in
            let previous = state
            state = box
            return previous
        }
        previous?.context.invalidate()
        return context
    }

    /// True while `context` is the current one: no lock and no newer prompt invalidated it.
    func isCurrent(_ context: LAContext) -> Bool {
        let id = ObjectIdentifier(context)
        return current.withLock { $0.map { ObjectIdentifier($0.context) } == id }
    }

    /// Evaluates `context` for Touch ID, in the in-app view bound to it if one shows (1.0 B11e2).
    func evaluate(_ context: LAContext) async throws(VaultError) {
        guard isCurrent(context) else { throw .cancelled }
        do {
            _ = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: context.localizedReason)
        } catch {
            let code = (error as NSError).code
            throw Self.evaluationError(forLAErrorCode: code, isLockedOut: unavailableReason() == .lockout)
        }
    }

    /// An evaluation's `LAError`, mapped as a keychain read's status is: a failed match sends
    /// the user to the password field (or names the lockout), never deletes the item.
    static func evaluationError(forLAErrorCode code: Int, isLockedOut: Bool) -> VaultError {
        if LAError.Code(rawValue: code) == .authenticationFailed {
            return isLockedOut ? .biometryUnavailable(.lockout) : .passwordFallbackRequested
        }
        if isPasswordFallback(laErrorCode: code) {
            return .passwordFallbackRequested
        }
        if isCancellation(laErrorCode: code) {
            return .cancelled
        }
        return .biometryUnavailable(unavailableReason(forLAErrorCode: code) ?? .notAvailable)
    }

    /// A context that never shows UI, for presence checks and attribute queries (§5.5).
    func silentContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    /// Invalidates the current context, if any (every lock, §5.5). A prompt still on screen ends
    /// with a cancellation.
    public func invalidate() {
        let box = current.withLock { state in
            let box = state
            state = nil
            return box
        }
        box?.context.invalidate()
    }

    // MARK: - Availability

    /// Why biometric authentication cannot run right now, or nil when it can.
    public func unavailableReason() -> BiometryUnavailableReason? {
        Self.evaluateAvailability()
    }

    /// `canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` on a throwaway context,
    /// mapped to a reason (nil when Touch ID can run).
    static func evaluateAvailability() -> BiometryUnavailableReason? {
        var error: NSError?
        guard !LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return nil
        }
        return unavailableReason(forLAErrorCode: error?.code) ?? .notAvailable
    }

    // MARK: - Error mapping (§5.5)

    /// The reason for an `LAError` code that means "Touch ID cannot be used", or nil for other
    /// codes (cancellations, failures).
    static func unavailableReason(forLAErrorCode rawCode: Int?) -> BiometryUnavailableReason? {
        guard let rawCode, let code = LAError.Code(rawValue: rawCode) else { return nil }
        switch code {
        case .biometryNotAvailable, .biometryNotPaired, .biometryDisconnected:
            return .notAvailable
        case .biometryNotEnrolled:
            return .notEnrolled
        case .biometryLockout:
            return .lockout
        case .passcodeNotSet:
            return .passcodeNotSet
        default:
            return nil
        }
    }

    /// True for `LAError` codes that end a prompt without a result the user should see as an
    /// error: cancel, system or app cancel, an invalidated context. The password fallback is
    /// not a cancellation (see ``isPasswordFallback(laErrorCode:)``).
    static func isCancellation(laErrorCode rawCode: Int) -> Bool {
        guard let code = LAError.Code(rawValue: rawCode) else { return false }
        switch code {
        case .userCancel, .systemCancel, .appCancel, .invalidContext, .notInteractive:
            return true
        default:
            return false
        }
    }

    /// True when the user chose the prompt's fallback button ("Use Master Password", §5.5).
    static func isPasswordFallback(laErrorCode rawCode: Int) -> Bool {
        LAError.Code(rawValue: rawCode) == .userFallback
    }

    /// `touchIDAuthenticationAllowableReuseDuration`: never reuse an earlier authentication.
    private static let noReuse: TimeInterval = 0
}
