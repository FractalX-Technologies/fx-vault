import VaultCore

/// Every error SharingKit throws (tasks/todo.md §4.4). Typed, `Sendable`, no localized text:
/// the app maps each case to a title and message in `ShareError+Extension.swift`.
public enum ShareError: Error, Sendable, Hashable {
    /// Any `.fxvault` read failure: size, magic, version, header length, ids, bounds, key
    /// derivation, authentication or JSON. One case on purpose, so the UI shows the single
    /// message "Wrong passphrase or damaged file" (§9.1) and nothing leaks which check failed.
    case invalidFile
    /// The decrypted or received package breaks a `SharePackageValidator` rule (§9.3).
    case invalidPackage(SharePackageViolation)
    /// The typed passphrase is not six words from the share wordlist (§9.2).
    case invalidPassphrase(PassphraseIssue)
    /// The bundled wordlist is missing or does not match its pinned SHA-256.
    case wordlistUnavailable
    /// The package is larger than ``Limits/maxSharePayloadBytes``.
    case payloadTooLarge
    /// Sealing a file or frame failed (CryptoKit error or key derivation failure on export).
    case encryptionFailed
    /// The task was cancelled (for example while Argon2id was running).
    case cancelled
    /// The import plan cannot apply the requested action to this item or environment.
    case importActionNotAllowed
    /// The share file's `expiresAt` has passed (v0.9.0).
    case expired
}

/// Why a typed passphrase was rejected (§9.2). Never carries the typed text.
public enum PassphraseIssue: Sendable, Hashable {
    /// The input did not split into exactly ``Limits/passphraseWordCount`` words.
    case wrongWordCount(found: Int)
    /// The word at this zero-based position is not in the share wordlist.
    case unknownWord(position: Int)
}
