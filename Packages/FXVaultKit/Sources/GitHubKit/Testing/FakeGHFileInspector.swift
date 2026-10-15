import Darwin
import Foundation
import os

/// A scripted ``GHFileInspecting`` for tests and previews: files, folders and symlinks with
/// owners, groups and modes, so tests can model a gh that another user owns (which a test process
/// cannot create on disk). Nothing touches the real file system.
public final class FakeGHFileInspector: GHFileInspecting, Sendable {
    /// The uid the fake runs as unless told otherwise.
    public static let defaultUserID: uid_t = 501
    /// `wheel` on macOS.
    public static let wheelGroupID: gid_t = 0
    /// `admin` on macOS.
    public static let adminGroupID: gid_t = 80
    /// `staff` on macOS: group write by it is not privileged.
    public static let staffGroupID: gid_t = 20
    /// `rwxr-xr-x`.
    public static let executableMode: mode_t = 0o755
    /// `rwxrwxr-x` (Homebrew's `/opt/homebrew/bin`).
    public static let groupWritableFolderMode: mode_t = 0o775

    private struct Node: Sendable {
        var status: GHFileStatusModel
        var isExecutable: Bool
    }

    private struct State: Sendable {
        var nodes: [String: Node] = [:]
        var links: [String: String] = [:]
        var userNames: [uid_t: String] = [:]
    }

    private static let maxLinkDepth = 8
    private static let fileType = mode_t(S_IFREG)
    private static let folderType = mode_t(S_IFDIR)

    public let currentUserID: uid_t
    public let privilegedGroupIDs: Set<gid_t>
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(
        currentUserID: uid_t = defaultUserID,
        privilegedGroupIDs: Set<gid_t> = [wheelGroupID, adminGroupID]
    ) {
        self.currentUserID = currentUserID
        self.privilegedGroupIDs = privilegedGroupIDs
    }

    // MARK: - Scripting

    /// Adds (or replaces) a folder.
    public func addFolder(_ path: String, owner: uid_t, group: gid_t = adminGroupID, mode: mode_t = executableMode) {
        state.withLock {
            $0.nodes[path] = Node(status: GHFileStatusModel(mode: Self.folderType | mode, ownerID: owner, groupID: group), isExecutable: true)
        }
    }

    /// Adds (or replaces) a regular file; executable when `mode` has a user execute bit.
    public func addFile(_ path: String, owner: uid_t, group: gid_t = adminGroupID, mode: mode_t = executableMode) {
        state.withLock {
            $0.nodes[path] = Node(
                status: GHFileStatusModel(mode: Self.fileType | mode, ownerID: owner, groupID: group),
                isExecutable: mode & mode_t(S_IXUSR) != 0
            )
        }
    }

    /// Adds a symlink at `path` pointing to the absolute `target`.
    public func addSymlink(_ path: String, to target: String) {
        state.withLock { $0.links[path] = target }
    }

    /// Changes the owner of an existing file or folder (for example Homebrew reinstalled by
    /// another administrator).
    public func setOwner(_ path: String, to owner: uid_t) {
        state.withLock { state in
            guard let node = state.nodes[path] else { return }
            state.nodes[path] = Node(
                status: GHFileStatusModel(mode: node.status.mode, ownerID: owner, groupID: node.status.groupID),
                isExecutable: node.isExecutable
            )
        }
    }

    /// Names a user for ``userName(for:)``.
    public func setUserName(_ name: String, for uid: uid_t) {
        state.withLock { $0.userNames[uid] = name }
    }

    /// A Homebrew-style install owned by `owner`: `<prefix>/bin/gh` → `<prefix>/Cellar/gh/<version>/bin/gh`,
    /// with `<prefix>/bin` `rwxrwxr-x` group `admin`. Returns the symlink path.
    @discardableResult
    public func addHomebrewGH(prefix: String = "/opt/homebrew", version: String = "2.102.0", owner: uid_t) -> String {
        let bin = prefix + "/bin"
        let cellarBin = prefix + "/Cellar/gh/\(version)/bin"
        addFolder(bin, owner: owner, mode: Self.groupWritableFolderMode)
        addFolder(cellarBin, owner: owner)
        addFile(cellarBin + "/gh", owner: owner)
        addSymlink(bin + "/gh", to: cellarBin + "/gh")
        return bin + "/gh"
    }

    // MARK: - GHFileInspecting

    public func exists(atPath path: String) -> Bool {
        state.withLock { $0.nodes[path] != nil || $0.links[path] != nil }
    }

    public func resolvedPath(_ path: String) -> String? {
        state.withLock { state in
            var current = path
            for _ in 0..<Self.maxLinkDepth {
                if let target = state.links[current] {
                    current = target
                    continue
                }
                return state.nodes[current] == nil ? nil : current
            }
            return nil
        }
    }

    public func status(atPath path: String) -> GHFileStatusModel? {
        guard let resolved = resolvedPath(path) else { return nil }
        return state.withLock { $0.nodes[resolved]?.status }
    }

    public func isExecutable(atPath path: String) -> Bool {
        guard let resolved = resolvedPath(path) else { return false }
        return state.withLock { $0.nodes[resolved]?.isExecutable ?? false }
    }

    public func userName(for uid: uid_t) -> String? {
        state.withLock { $0.userNames[uid] }
    }
}
