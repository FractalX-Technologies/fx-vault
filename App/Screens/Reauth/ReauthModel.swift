import Foundation
import Observation
import VaultCore
import VaultData

/// A single-use proof of presence from `ReauthGate` (D30): what ``ReauthModel`` hands out.
protocol ReauthAuthorization: AnyObject, Sendable {
    var isUsable: Bool { get }
}

extension ShareAuthorizationModel: ReauthAuthorization {}
extension EnvExportAuthorizationModel: ReauthAuthorization {}
extension FolderFileSaveAuthorizationModel: ReauthAuthorization {}

/// "Confirm it's you" before a share or Copy All (D30, §5.6): Touch ID first, and after any
/// Touch ID failure the master password, through `ReauthGate`. The repository consumes the
/// single-use authorization, so nothing leaves without it; the typed password is cleared after
/// every attempt and by ``reset()`` (the owner calls it on lock).
@Observable
final class ReauthModel<Authorization: ReauthAuthorization> {
    var password = ""
    private(set) var isAuthorizing = false
    /// Hidden after Touch ID reported it cannot be used on this Mac or build.
    private(set) var canUseTouchID = true
    /// Set when the password field should take focus ("Use Master Password").
    private(set) var focusPasswordRequest = 0
    private(set) var error: ErrorPresentationModel?
    /// The authorization, until ``takeAuthorization()`` hands it out.
    private(set) var authorization: Authorization?

    @ObservationIgnored private let prompt: BiometricPrompt
    @ObservationIgnored private let grant: (ReauthCredential) async throws -> Authorization

    /// A known `touchIDStatus` other than `.available` offers only the password; nil (unknown)
    /// tries Touch ID once and hides it after the first failure. `grant` asks `ReauthGate`.
    init(
        prompt: BiometricPrompt,
        touchIDStatus: BiometricUnlockStatus? = nil,
        grant: @escaping (ReauthCredential) async throws -> Authorization
    ) {
        self.prompt = prompt
        canUseTouchID = touchIDStatus.map { $0 == .available } ?? true
        self.grant = grant
    }

    var isAuthorized: Bool {
        authorization?.isUsable == true
    }

    var canSubmitPassword: Bool {
        !password.isEmpty && !isAuthorizing
    }

    /// Tries Touch ID. `automatic` (the first attempt when the step appears) reports no error,
    /// so a Mac without Touch ID simply shows the password field.
    @discardableResult
    func authorizeWithTouchID(automatic: Bool = false) async -> Bool {
        guard canUseTouchID, !isAuthorizing, !isAuthorized else { return isAuthorized }
        return await authorize(with: .biometrics(prompt), automatic: automatic)
    }

    /// Verifies the typed master password.
    @discardableResult
    func authorizeWithPassword() async -> Bool {
        guard canSubmitPassword, !isAuthorized else { return isAuthorized }
        let typed = password
        password = ""
        return await authorize(with: .password(typed), automatic: false)
    }

    /// Hands out the authorization once (it is single-use anyway).
    func takeAuthorization() -> Authorization? {
        defer { authorization = nil }
        return authorization?.isUsable == true ? authorization : nil
    }

    /// Drops the typed password and any unused authorization (lock, sheet closed).
    func reset() {
        password = ""
        authorization = nil
        error = nil
        isAuthorizing = false
    }

    func clearError() {
        error = nil
    }

    private func authorize(with credential: ReauthCredential, automatic: Bool) async -> Bool {
        isAuthorizing = true
        error = nil
        defer { isAuthorizing = false }
        do {
            authorization = try await grant(credential)
            return true
        } catch let failure as VaultError {
            handle(failure, credential: credential, automatic: automatic)
        } catch {
            if !error.isCancellation {
                self.error = error.presentation
            }
        }
        return false
    }

    private func handle(_ failure: VaultError, credential: ReauthCredential, automatic: Bool) {
        switch failure {
        case .cancelled:
            break
        case .passwordFallbackRequested:
            focusPasswordRequest += 1
        case .biometryUnavailable, .biometryInvalidated:
            canUseTouchID = false
            focusPasswordRequest += 1
            if !automatic {
                error = (failure as any Error).presentation
            }
        case .passwordRequired:
            focusPasswordRequest += 1
            if !automatic {
                error = (failure as any Error).presentation
            }
        default:
            if case .password = credential {
                focusPasswordRequest += 1
            }
            error = (failure as any Error).presentation
        }
    }
}

/// A share's confirmation (`.fxvault` file export).
typealias ShareReauthModel = ReauthModel<ShareAuthorizationModel>

extension ReauthModel where Authorization == ShareAuthorizationModel {
    convenience init(
        purpose: ShareAuthorizationPurpose,
        reauth: ReauthGate,
        session: VaultSession,
        touchIDStatus: BiometricUnlockStatus? = nil
    ) {
        self.init(prompt: FeatureDependencies.reauthPrompt(for: .share), touchIDStatus: touchIDStatus) { credential in
            try await reauth.authorizeShare(purpose, with: credential, session: session)
        }
    }
}
