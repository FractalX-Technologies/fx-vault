import Foundation
import VaultCore
import VaultStore

/// Stores the DEK in a Touch ID-protected keychain item (§5.5, D14).
///
/// ``KeychainManager`` is the live implementation (data-protection keychain,
/// `.biometryCurrentSet`); ``FakeBiometricKeyStore`` stands in for tests and previews, so no test
/// ever shows a real Touch ID prompt. Every method is synchronous; ``load(account:prompt:)``
/// blocks while the prompt is on screen, so ``VaultManager`` calls it off the main actor on a
/// dispatch queue.
///
/// Errors are `VaultError`:
/// - `.biometryInvalidated`: the item is gone or no longer usable (enrollment changed);
/// - `.cancelled`: the user cancelled;
/// - `.passwordFallbackRequested`: the user chose the password fallback button, or Touch ID did
///   not recognize the finger (the item stays);
/// - `.biometryUnavailable(reason)`: Touch ID or the keychain cannot be used now.
public protocol BiometricKeyStoring: Sendable {
    /// Creates (or replaces) the item for `account` holding `dek`. Never prompts. The caller
    /// wipes `dek`.
    func store(_ dek: SecretBytes, account: String) throws(VaultError)

    /// Reads the item for `account`, showing the Touch ID prompt. The caller wipes the result.
    func load(account: String, prompt: BiometricPrompt) throws(VaultError) -> SecretBytes

    /// A fresh check for an in-app Touch ID view (1.0 B11e2), the current context from now on (a
    /// lock invalidates it). Never prompts.
    func makeSession(prompt: BiometricPrompt) -> BiometricSession

    /// True until a lock or a newer prompt invalidates the session's context.
    func isCurrent(_ session: BiometricSession) -> Bool

    /// Runs the session's check: inside the `LAAuthenticationView` showing its context, else as
    /// the system prompt. Throws as ``load(account:prompt:)`` does (cancel, fallback, lockout).
    func evaluate(_ session: BiometricSession) async throws(VaultError)

    /// Reads the item for `account` with the evaluated session's context, without a second
    /// prompt; `.cancelled` once a lock invalidated it. The caller wipes the result.
    func load(account: String, session: BiometricSession) throws(VaultError) -> SecretBytes

    /// True when an item exists for `account`, checked without any UI (§5.5 presence check).
    func contains(account: String) throws(VaultError) -> Bool

    /// Deletes the item for `account`. Deleting a missing item succeeds.
    func delete(account: String) throws(VaultError)

    /// The accounts of every item of the FX Vault DEK service, for orphan cleanup.
    func allAccounts() throws(VaultError) -> [String]

    /// Invalidates the authentication context of a pending or finished prompt (every lock,
    /// §5.5). Synchronous and safe to call from any thread.
    func invalidateAuthentication()
}

/// Names of the Touch ID keychain items (§5.5).
public enum BiometricKeyAccount {
    /// Keychain service of the DEK items of this build's flavor. Signed Debug and Release builds
    /// share one access group but use separate vaults (`FX Vault Dev` / `FX Vault`), so each
    /// flavor has its own service: a Debug build's orphan cleanup or reset can never delete the
    /// installed release vault's item.
    public static var service: String {
        service(for: .current)
    }

    /// `io.fractalx.fxvault.dek` for release, `io.fractalx.fxvault.dek.dev` for debug.
    public static func service(for flavor: DatabaseFactory.Flavor) -> String {
        switch flavor {
        case .release: releaseService
        case .debug: releaseService + debugServiceSuffix
        }
    }

    private static let releaseService = "io.fractalx.fxvault.dek"
    private static let debugServiceSuffix = ".dev"
    /// Prefix of every account name; the vault id follows in lowercase hex.
    public static let prefix = "touchid-v1-"

    /// `touchid-v1-<vault_id hex>`.
    public static func name(vaultID: Data) -> String {
        prefix + vaultID.map { byte in
            let hex = String(byte, radix: hexRadix)
            return hex.count < hexDigitsPerByte ? "0" + hex : hex
        }.joined()
    }

    private static let hexRadix = 16
    private static let hexDigitsPerByte = 2
}
