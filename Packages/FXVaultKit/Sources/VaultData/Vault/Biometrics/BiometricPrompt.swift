/// The Touch ID prompt texts (§4.6, D24).
///
/// Packages ship no user-facing text: the app builds this with `String(localized:)` and passes it
/// to ``VaultManager/unlockWithBiometrics(prompt:)`` and ``ReauthGate``. `scripts/lint.sh`
/// rejects literal assignments to `localizedReason` / `localizedFallbackTitle` in Sources.
public struct BiometricPrompt: Sendable, Hashable {
    /// Why FX Vault asks (`LAContext.localizedReason`), for example "unlock your vault".
    public let reason: String
    /// Title of the fallback button (`LAContext.localizedFallbackTitle`), for example "Use
    /// Password". Choosing it ends the prompt with `VaultError.passwordFallbackRequested`, and the
    /// app shows and focuses the password field.
    public let fallbackTitle: String

    public init(reason: String, fallbackTitle: String) {
        self.reason = reason
        self.fallbackTitle = fallbackTitle
    }
}
