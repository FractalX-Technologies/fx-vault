import Darwin
import Foundation
import VaultCore

/// The empty working directory every child starts in (tasks/todo.md §5.10):
/// `~/Library/Caches/io.fractalx.fxvault/empty-cwd`, mode 0700.
///
/// A fixed empty directory means gh never picks up a repository from the current directory
/// (no implicit `GH_REPO`-like context) and git never runs hooks or config from one.
public enum EmptyWorkingDirectory {
    public static let bundleDirectoryName = "io.fractalx.fxvault"
    public static let directoryName = "empty-cwd"
    static let permissions: mode_t = 0o700
    private static let typeMask = mode_t(S_IFMT)
    private static let directoryType = mode_t(S_IFDIR)

    /// Creates (or checks) `<cachesDirectory>/io.fractalx.fxvault/empty-cwd` with mode 0700.
    /// Throws ``GHError/launchFailed`` when the path exists but is not a directory owned by the
    /// user (for example a symlink).
    public static func prepare(in cachesDirectory: URL) throws(GHError) -> URL {
        let parent = cachesDirectory.appendingPathComponent(bundleDirectoryName, isDirectory: true)
        let directory = parent.appendingPathComponent(directoryName, isDirectory: true)
        for url in [parent, directory] {
            try ensureDirectory(url)
        }
        return directory
    }

    /// ``prepare(in:)`` in the user's caches directory.
    public static func prepareDefault() throws(GHError) -> URL {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw .launchFailed
        }
        return try prepare(in: caches)
    }

    private static func ensureDirectory(_ url: URL) throws(GHError) {
        let path = url.path
        if mkdir(path, permissions) != 0 && errno != EEXIST {
            throw .launchFailed
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & typeMask == directoryType,
              info.st_uid == getuid(),
              chmod(path, permissions) == 0
        else { throw .launchFailed }
    }
}
