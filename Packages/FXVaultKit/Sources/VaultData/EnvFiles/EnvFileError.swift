import EnvTools
import Foundation
import VaultCore

/// Why an ``EnvFileRepository`` operation failed. Carries no values, file contents or localized
/// text; the app maps each case in `EnvFileError+Extension.swift`.
public enum EnvFileError: Error, Sendable, Hashable {
    /// The `.env` file could not be read.
    case fileUnreadable
    /// The `.env` file was rejected as a whole (too large).
    case parse(DotEnvParseError)
    /// The export could not be serialized (never expected for GitHub names).
    case serialize(DotEnvSerializeError)
    /// The export file could not be written (symlink, existing file, permissions, ...).
    case write(SecureFileWriteError)
    /// The authorization is missing, already used, from another session, or the vault was
    /// locked since it was granted: ask `ReauthGate` again.
    case authorizationInvalid
    /// `.gitignore` exists but is not a regular file (for example a symbolic link).
    case gitignoreNotRegularFile
    /// `.gitignore` could not be read as UTF-8.
    case gitignoreUnreadable
    /// Reading or writing the vault failed.
    case config(ConfigRepositoryError)
}
