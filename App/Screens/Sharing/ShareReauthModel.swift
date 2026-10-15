import Foundation
import Observation
import VaultCore
import VaultData

/// The re-authentication step of a share (D30, §5.6): Touch ID or the master password, through
/// `ReauthGate.authorizeShare`. The result is a single-use ``ShareAuthorizationModel`` that
/// ``SharingRepository`` consumes, so nothing is exported or sent without it.
///
/// Touch ID is tried first; any Touch ID failure (cancel, "Use Master Password", not enabled,
/// unavailable, invalidated) falls back to the password field. The typed password lives only
/// here and is cleared after every attempt and by ``reset()`` (the owner calls it on lock).
@Observable
final class ShareReauthModel {
    let purpose: ShareAuthorizationPurpose
    var password = ""
    private(set) var isAuthorizing = false
    /// Hidden after Touch ID reported it cannot be used on this Mac or build.
    private(set) var canUseTouchID = true
    /// Set when the password field should take focus ("Use Master Password").
    private(set) var focusPasswordRequest = 0
    private(set) var error: ErrorPresentationModel?
    /// The authorization, until ``takeAuthorization()`` hands it out.
    private(set) var authorization: ShareAuthorizationModel?

    @ObservationIgnored private let reauth: ReauthGate
    @ObservationIgnored private let session: VaultSession

    /// - Parameter touchIDStatus: the vault's Touch ID status (`FeatureDependencies.touchIDStatus`);
    ///   when known and not `.available`, only the password is offered. nil (unknown) tries Touch
    ///   ID once and hides it after the first failure.
    init(
        purpose: ShareAuthorizationPurpose,
        reauth: ReauthGate,
        session: VaultSession,
        touchIDStatus: BiometricUnlockStatus? = nil
    ) {
        self.purpose = purpose
        canUseTouchID = touchIDStatus.map { $0 == .available } ?? true
        self.reauth = reauth
        self.session = session
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
        let prompt = FeatureDependencies.reauthPrompt(for: purpose == .fileExport ? .share : .nearbySend)
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
    func takeAuthorization() -> ShareAuthorizationModel? {
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
            authorization = try await reauth.authorizeShare(purpose, with: credential, session: session)
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
