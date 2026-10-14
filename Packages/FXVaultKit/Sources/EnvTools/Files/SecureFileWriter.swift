import Darwin
import Foundation
import VaultCore

/// The system call that failed inside ``SecureFileWriter``.
public enum SecureFileOperation: String, Sendable, Hashable {
    case inspectDestination
    case createTemporaryFile
    case setPermissions
    case write
    case synchronize
    case close
    case rename
}

/// Why ``SecureFileWriter`` refused or failed. Never carries file contents.
public enum SecureFileWriteError: Error, Sendable, Hashable {
    /// The destination is not a `file://` URL.
    case notAFileURL
    /// The destination's last path component is empty, `.`, `..` or contains a NUL byte.
    case invalidFileName
    /// The destination's folder does not exist or is not a folder.
    case parentDirectoryUnavailable
    /// The destination is a symbolic link. FX Vault never writes through links.
    case destinationIsSymbolicLink
    /// The destination exists and is not a regular file.
    case destinationIsNotRegularFile
    /// The destination exists and the policy is ``SecureFileWriter/ExistingFilePolicy/fail``.
    case destinationExists
    /// A system call failed with this `errno`.
    case systemCall(SecureFileOperation, errno: Int32)
}

/// Writes exported plaintext (`.env`) and `.fxvault` files (§5.13).
///
/// 1. Refuses a destination that is a symbolic link or not a regular file.
/// 2. Creates a sibling temporary file with
///    `open(O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600)`, so the file is never
///    readable by anyone else, not even for an instant (the umask can only narrow it; `fchmod`
///    then pins it to exactly 0600).
/// 3. Writes everything, flushes with `F_FULLFSYNC` (falling back to `fsync`), closes.
/// 4. Renames over the destination: `renamex_np(RENAME_EXCL)` when an existing file must not be
///    replaced, `rename` otherwise. `rename` replaces a link that appears in between instead of
///    following it.
/// 5. Flushes the folder (best effort). On any failure the temporary file is removed.
///
/// Never uses `Data.write(options: .atomic)`, whose temporary file gets default permissions.
/// The caller wipes the `SecretBytes` it passed in.
public struct SecureFileWriter: Sendable {
    /// What to do when the destination already exists as a regular file.
    public enum ExistingFilePolicy: Sendable, Hashable {
        /// Throw ``SecureFileWriteError/destinationExists``.
        case fail
        /// Replace it atomically (the new file is a new inode with mode 0600).
        case replace
    }

    /// Owner read and write only.
    public static let fileMode: mode_t = S_IRUSR | S_IWUSR
    private static let temporaryPrefix = ".fxvault-"
    private static let temporarySuffix = ".tmp"

    /// Test seam: called with the temporary file's path right after it is created and before
    /// anything is written, so tests can `stat` it.
    private let onTemporaryFileCreated: (@Sendable (String) -> Void)?

    public init() {
        onTemporaryFileCreated = nil
    }

    init(onTemporaryFileCreated: @escaping @Sendable (String) -> Void) {
        self.onTemporaryFileCreated = onTemporaryFileCreated
    }

    /// Writes `contents` to `destination` with mode 0600.
    public func write(
        _ contents: SecretBytes,
        to destination: URL,
        existingFile: ExistingFilePolicy = .fail
    ) throws(SecureFileWriteError) {
        let target = try resolveTarget(destination, existingFile: existingFile)
        try contents.withUnsafeBytes { bytes throws(SecureFileWriteError) in
            try writeFile(bytes, target: target, existingFile: existingFile)
        }
    }

    /// Writes `data` (for example an encrypted `.fxvault` package) to `destination` with
    /// mode 0600.
    public func write(
        _ data: Data,
        to destination: URL,
        existingFile: ExistingFilePolicy = .fail
    ) throws(SecureFileWriteError) {
        let target = try resolveTarget(destination, existingFile: existingFile)
        let result: Result<Void, SecureFileWriteError> = data.withUnsafeBytes { bytes in
            Result { () throws(SecureFileWriteError) in
                try writeFile(bytes, target: target, existingFile: existingFile)
            }
        }
        try result.get()
    }

    // MARK: - Steps

    private struct Target {
        let directoryPath: String
        let destinationPath: String
    }

    private func resolveTarget(
        _ destination: URL,
        existingFile: ExistingFilePolicy
    ) throws(SecureFileWriteError) -> Target {
        guard destination.isFileURL else { throw .notAFileURL }
        let name = destination.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name != "/", !name.contains("\0") else {
            throw .invalidFileName
        }
        let directoryPath = destination.deletingLastPathComponent().path(percentEncoded: false)

        var directoryStatus = stat()
        guard stat(directoryPath, &directoryStatus) == 0,
              directoryStatus.st_mode & S_IFMT == S_IFDIR
        else { throw .parentDirectoryUnavailable }

        let destinationPath = (directoryPath as NSString).appendingPathComponent(name)
        var destinationStatus = stat()
        if lstat(destinationPath, &destinationStatus) == 0 {
            switch destinationStatus.st_mode & S_IFMT {
            case S_IFLNK:
                throw .destinationIsSymbolicLink
            case S_IFREG:
                if existingFile == .fail { throw .destinationExists }
            default:
                throw .destinationIsNotRegularFile
            }
        } else if errno != ENOENT {
            throw .systemCall(.inspectDestination, errno: errno)
        }
        return Target(directoryPath: directoryPath, destinationPath: destinationPath)
    }

    private func writeFile(
        _ bytes: UnsafeRawBufferPointer,
        target: Target,
        existingFile: ExistingFilePolicy
    ) throws(SecureFileWriteError) {
        let temporaryName = Self.temporaryPrefix + UUID().uuidString + Self.temporarySuffix
        let temporaryPath = (target.directoryPath as NSString).appendingPathComponent(temporaryName)

        let descriptor = open(
            temporaryPath,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            Self.fileMode
        )
        guard descriptor >= 0 else { throw .systemCall(.createTemporaryFile, errno: errno) }
        onTemporaryFileCreated?(temporaryPath)

        var isOpen = true
        do throws(SecureFileWriteError) {
            guard fchmod(descriptor, Self.fileMode) == 0 else {
                throw .systemCall(.setPermissions, errno: errno)
            }
            try writeAll(bytes, to: descriptor)
            try synchronize(descriptor)
            isOpen = false
            guard close(descriptor) == 0 else { throw .systemCall(.close, errno: errno) }
            try rename(from: temporaryPath, to: target.destinationPath, existingFile: existingFile)
        } catch {
            if isOpen { close(descriptor) }
            unlink(temporaryPath)
            throw error
        }
        synchronizeDirectory(target.directoryPath)
    }

    private func writeAll(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32) throws(SecureFileWriteError) {
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(descriptor, base + offset, bytes.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                throw .systemCall(.write, errno: errno)
            }
            offset += written
        }
    }

    private func synchronize(_ descriptor: Int32) throws(SecureFileWriteError) {
        // F_FULLFSYNC asks the drive to flush its cache; some file systems (SMB, FAT) do not
        // support it, so fall back to fsync.
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else { throw .systemCall(.synchronize, errno: errno) }
    }

    private func rename(
        from source: String,
        to destination: String,
        existingFile: ExistingFilePolicy
    ) throws(SecureFileWriteError) {
        switch existingFile {
        case .fail:
            guard renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 else {
                let code = errno
                throw code == EEXIST ? .destinationExists : .systemCall(.rename, errno: code)
            }
        case .replace:
            guard Darwin.rename(source, destination) == 0 else {
                throw .systemCall(.rename, errno: errno)
            }
        }
    }

    /// Flushes the folder entry for the rename. Best effort: a failure here does not undo a
    /// complete, renamed file.
    private func synchronizeDirectory(_ path: String) {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        fsync(descriptor)
        close(descriptor)
    }
}
