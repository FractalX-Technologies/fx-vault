import Foundation

/// What gh and the login-shell probe print, for ``FakeCommandRunner`` stubs (AppTests and the
/// UI-testing host, which never run a real gh or shell). Synthetic names only.
public enum FakeGHOutput {
    /// The shell probe's output: `ghPath` from `command -v gh`, the variables the shell sets
    /// (names), `GH_CONFIG_DIR` with `configDir` as its value, and `PATH`.
    public static func shellProbe(
        ghPath: String?,
        variables: [String] = [],
        configDir: String? = nil,
        path: String = "/opt/homebrew/bin:/usr/bin:/bin"
    ) -> String {
        var entries = ["\(ShellEnvironmentResolver.beginMarker)PATH=\(path)\n"]
        if let configDir {
            entries.append("GH_CONFIG_DIR=\(configDir)\n")
        }
        entries.append("\(ShellEnvironmentResolver.ghPathKey)=\(ghPath ?? "")\n")
        entries += variables.map { "\(ShellEnvironmentResolver.flagKey)=\($0)" }
        entries.append(ShellEnvironmentResolver.endMarker)
        return entries.joined(separator: "\0")
    }

    /// One `gh repo view` / `gh repo list` entry (the `--json` fields FX Vault requests).
    public static func repo(owner: String, name: String, permission: String = "WRITE") -> String {
        """
        {"createdAt":"2026-01-02T03:04:05Z","defaultBranchRef":{"name":"main"},"id":"R_\(owner)_\(name)",\
        "isArchived":false,"isFork":false,"isPrivate":true,"name":"\(name)","nameWithOwner":"\(owner)/\(name)",\
        "owner":{"id":"O_\(owner)","login":"\(owner)"},"sshUrl":"git@github.com:\(owner)/\(name).git",\
        "viewerCanAdminister":\(permission == "ADMIN"),"viewerPermission":"\(permission)","visibility":"PRIVATE"}
        """
    }
}
