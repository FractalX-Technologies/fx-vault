import Darwin
import Foundation

/// The metadata of one file or folder the gh trust check reads (`stat`).
public struct GHFileStatusModel: Sendable, Hashable {
    public let mode: mode_t
    public let ownerID: uid_t
    public let groupID: gid_t

    public init(mode: mode_t, ownerID: uid_t, groupID: gid_t) {
        self.mode = mode
        self.ownerID = ownerID
        self.groupID = groupID
    }

    private static let typeMask = mode_t(S_IFMT)
    private static let regularFileType = mode_t(S_IFREG)

    public var isRegularFile: Bool {
        mode & Self.typeMask == Self.regularFileType
    }
}

/// What ``GHLocator`` reads from the file system and the user database (§5.10).
/// ``SystemGHFileInspector`` is live; tests use ``FakeGHFileInspector`` to model files that
/// other users own, which a test process cannot create.
public protocol GHFileInspecting: Sendable {
    /// The user FX Vault runs as.
    var currentUserID: uid_t { get }
    /// Groups whose members can already become root (`wheel`, `admin`): group write by them
    /// grants nothing extra and is accepted.
    var privilegedGroupIDs: Set<gid_t> { get }
    /// True when something exists at `path` without following a final symlink (`lstat`).
    func exists(atPath path: String) -> Bool
    /// `path` with every symlink resolved (`realpath`), or nil.
    func resolvedPath(_ path: String) -> String?
    /// `stat` of `path` (follows symlinks), or nil.
    func status(atPath path: String) -> GHFileStatusModel?
    /// `access(path, X_OK)`.
    func isExecutable(atPath path: String) -> Bool
    /// The account name of `uid` in the user database, or nil.
    func userName(for uid: uid_t) -> String?
}

/// ``GHFileInspecting`` over Darwin (`lstat`, `realpath`, `stat`, `access`, `getpwuid`).
public struct SystemGHFileInspector: GHFileInspecting {
    private static let rootGroupID: gid_t = 0
    private static let adminGroupName = "admin"

    public init() {}

    public var currentUserID: uid_t {
        getuid()
    }

    public var privilegedGroupIDs: Set<gid_t> {
        var groups: Set<gid_t> = [Self.rootGroupID]
        if let admin = getgrnam(Self.adminGroupName) {
            groups.insert(admin.pointee.gr_gid)
        }
        return groups
    }

    public func exists(atPath path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    public func resolvedPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    public func status(atPath path: String) -> GHFileStatusModel? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return GHFileStatusModel(mode: info.st_mode, ownerID: info.st_uid, groupID: info.st_gid)
    }

    public func isExecutable(atPath path: String) -> Bool {
        access(path, X_OK) == 0
    }

    public func userName(for uid: uid_t) -> String? {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return nil }
        return String(cString: name)
    }
}
