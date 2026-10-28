import EnvTools
import Foundation

/// Why adding or saving a folder file failed (v23). Carries no names or bytes; the app maps
/// each case in `FolderCopy.swift`.
public enum FolderFileError: Error, Sendable, Hashable {
    /// Larger than `limit` bytes (``Limits/maxFolderFileBytes``).
    case tooLarge(limit: Int)
    /// Not a regular file, unreadable, or changed while it was read.
    case unreadable
    /// The authorization is missing, already used, from another session, or the vault was
    /// locked since it was granted: ask `ReauthGate` again.
    case authorizationInvalid
    /// The file could not be written (symlink, permissions, disk full, ...).
    case write(SecureFileWriteError)
    /// The saved file could not be marked as downloaded (a volume without extended attributes),
    /// so it was removed: Gatekeeper must check it before it opens.
    case quarantine
    /// The folder or file is gone, the name is invalid or taken, the vault is locked, ...
    case config(ConfigRepositoryError)
}
