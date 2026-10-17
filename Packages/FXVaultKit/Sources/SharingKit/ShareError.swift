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
    /// The nearby session ended with this abort (§9.4). The session cannot be resumed.
    case nearbyAborted(NearbyAbortReason)
    /// The requested nearby action is not allowed in the session's current phase
    /// (for example sending the manifest before both sides confirmed the code).
    case nearbyActionNotAllowed
    /// The nearby session already finished or aborted. There is no automatic retry: a new
    /// attempt needs a new session started by a new user action (D21).
    case nearbySessionFinished
    /// The nearby transport failed to send or deliver a frame.
    case transport(NearbyTransportFailure)
    /// The import plan cannot apply the requested action to this item or environment.
    case importActionNotAllowed
    /// A teammate card read back from the vault does not match its keys (v0.5.0).
    case teamCardInvalid
    /// This Mac's teammate keys in the vault have the wrong size or were rejected (v0.5.0).
    case teamKeysInvalid
    /// A space version could not be read (v0.6.0).
    case spaceVersionInvalid
    /// A space log broke a rule (v0.6.0).
    case spaceLogInvalid(SpaceLogFailure)
    /// A teammates file (format 2) has no slot for this Mac: it was sealed for other teammates (v0.9.0).
    case notARecipient
    /// A teammates file was sealed by a device that is not one of this vault's teammates, so its
    /// signature cannot be checked (v0.9.0).
    case senderNotTeammate
    /// The share file's `expiresAt` has passed (v0.9.0).
    case expired
    /// A remote pairing card (`.fxvcard`) is damaged, forged or not a reply to this Mac's
    /// invitation (v0.9.0).
    case invalidPairingCard
    /// A remote pairing invitation is too old, or dated in the future (v0.9.0).
    case pairingExpired
    /// The pairing card is this Mac's own (v0.9.0).
    case pairingOwnCard
}

/// Why a typed passphrase was rejected (§9.2). Never carries the typed text.
public enum PassphraseIssue: Sendable, Hashable {
    /// The input did not split into exactly ``Limits/passphraseWordCount`` words.
    case wrongWordCount(found: Int)
    /// The word at this zero-based position is not in the share wordlist.
    case unknownWord(position: Int)
}
