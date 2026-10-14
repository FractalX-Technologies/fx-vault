import Darwin
import Foundation
import VaultCore

/// The current user's identity values passed to every child (tasks/todo.md §5.10).
public struct ProcessIdentityModel: Sendable, Hashable {
    public var home: String
    public var user: String
    public var temporaryDirectory: String
    /// `SSH_AUTH_SOCK` from FX Vault's own environment (launchd sets it for GUI apps). The
    /// login-shell value wins when one was captured.
    public var sshAuthSocket: String?

    public init(home: String, user: String, temporaryDirectory: String, sshAuthSocket: String? = nil) {
        self.home = home
        self.user = user
        self.temporaryDirectory = temporaryDirectory
        self.sshAuthSocket = sshAuthSocket
    }

    /// The running user, from the password database (not from inherited variables, which a
    /// GUI app may not have).
    public static func current(processEnvironment: [String: String] = ProcessInfo.processInfo.environment)
        -> ProcessIdentityModel
    {
        var home = NSHomeDirectory()
        var user = NSUserName()
        if let entry = getpwuid(getuid()) {
            home = String(cString: entry.pointee.pw_dir)
            user = String(cString: entry.pointee.pw_name)
        }
        return ProcessIdentityModel(
            home: home,
            user: user,
            temporaryDirectory: FileManager.default.temporaryDirectory.path,
            sshAuthSocket: processEnvironment[ProcessEnvironmentBuilder.Key.sshAuthSock]
        )
    }
}

/// Builds the complete, allowlisted environment of every child process (§5.10, D7).
///
/// Nothing is inherited from FX Vault's own environment. The forbidden keys
/// (``forbiddenKeys``) can never appear: the builders only ever insert the keys listed here.
public enum ProcessEnvironmentBuilder {
    /// Environment variable names.
    public enum Key {
        public static let home = "HOME"
        public static let user = "USER"
        public static let logname = "LOGNAME"
        public static let tmpdir = "TMPDIR"
        public static let path = "PATH"
        public static let lang = "LANG"
        public static let ghConfigDir = "GH_CONFIG_DIR"
        public static let xdgConfigHome = "XDG_CONFIG_HOME"
        public static let xdgCacheHome = "XDG_CACHE_HOME"
        public static let xdgStateHome = "XDG_STATE_HOME"
        public static let sshAuthSock = "SSH_AUTH_SOCK"
        public static let ghHost = "GH_HOST"
        public static let ghPromptDisabled = "GH_PROMPT_DISABLED"
        public static let ghNoUpdateNotifier = "GH_NO_UPDATE_NOTIFIER"
        public static let ghNoExtensionUpdateNotifier = "GH_NO_EXTENSION_UPDATE_NOTIFIER"
        public static let ghPager = "GH_PAGER"
        public static let pager = "PAGER"
        public static let noColor = "NO_COLOR"
        public static let cliColor = "CLICOLOR"
        public static let ghSpinnerDisabled = "GH_SPINNER_DISABLED"
        public static let ghTelemetry = "GH_TELEMETRY"
        public static let doNotTrack = "DO_NOT_TRACK"
        public static let ghToken = "GH_TOKEN"
        public static let gitTerminalPrompt = "GIT_TERMINAL_PROMPT"
        public static let gitConfigNoSystem = "GIT_CONFIG_NOSYSTEM"
        public static let gitSSHCommand = "GIT_SSH_COMMAND"
        public static let resolvingEnvironment = "FXVAULT_RESOLVING_ENV"
        public static let term = "TERM"
    }

    /// Keys that must never reach a child (§5.10). Asserted by tests.
    public static let forbiddenKeys: Set<String> = [
        "GH_DEBUG", "DEBUG", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN",
        "GH_REPO", "GH_FORCE_TTY", "CLICOLOR_FORCE", "GH_EDITOR", "GH_BROWSER",
    ]

    /// Every key a gh child may receive.
    public static let ghAllowedKeys: Set<String> = [
        Key.home, Key.user, Key.logname, Key.tmpdir, Key.path, Key.lang,
        Key.ghConfigDir, Key.xdgConfigHome, Key.xdgCacheHome, Key.xdgStateHome,
        Key.ghHost, Key.ghPromptDisabled, Key.ghNoUpdateNotifier, Key.ghNoExtensionUpdateNotifier,
        Key.ghPager, Key.pager, Key.noColor, Key.cliColor, Key.ghSpinnerDisabled,
        Key.ghTelemetry, Key.doNotTrack, Key.ghToken,
    ]

    /// Every key a git child may receive.
    public static let gitAllowedKeys: Set<String> = [
        Key.home, Key.user, Key.path, Key.sshAuthSock, Key.lang,
        Key.gitTerminalPrompt, Key.gitConfigNoSystem, Key.gitSSHCommand,
    ]

    /// Every key an ssh child may receive.
    public static let sshAllowedKeys: Set<String> = [
        Key.home, Key.user, Key.path, Key.sshAuthSock, Key.lang,
    ]

    private static let enabled = "1"
    private static let disabled = "0"
    private static let pagerCommand = "cat"
    private static let telemetryOff = "false"
    private static let dumbTerminal = "dumb"

    /// The gh environment. `token` (the account's `GH_TOKEN`) is nil for `auth status`,
    /// `auth token` and `--version` (§8 A1, A3, A4). The token's bytes must be printable ASCII.
    public static func gh(
        identity: ProcessIdentityModel,
        shell: ShellEnvironmentModel,
        token: SecretBytes?
    ) throws(GHError) -> [String: String] {
        var environment: [String: String] = [
            Key.home: identity.home,
            Key.user: identity.user,
            Key.logname: identity.user,
            Key.tmpdir: identity.temporaryDirectory,
            Key.path: shell.resolvedPATH,
            Key.lang: GHConstants.processLanguage,
            Key.ghHost: GHConstants.host,
            Key.ghPromptDisabled: enabled,
            Key.ghNoUpdateNotifier: enabled,
            Key.ghNoExtensionUpdateNotifier: enabled,
            Key.ghPager: pagerCommand,
            Key.pager: pagerCommand,
            Key.noColor: enabled,
            Key.cliColor: disabled,
            Key.ghSpinnerDisabled: enabled,
            Key.ghTelemetry: telemetryOff,
            Key.doNotTrack: enabled,
        ]
        environment[Key.ghConfigDir] = shell.ghConfigDir
        environment[Key.xdgConfigHome] = shell.xdgConfigHome
        environment[Key.xdgCacheHome] = shell.xdgCacheHome
        environment[Key.xdgStateHome] = shell.xdgStateHome
        if let token {
            environment[Key.ghToken] = try tokenString(token)
        }
        return environment
    }

    /// The git environment (§5.10): no system config, no terminal prompts, ssh in batch mode.
    public static func git(identity: ProcessIdentityModel, shell: ShellEnvironmentModel) -> [String: String] {
        var environment = ssh(identity: identity, shell: shell)
        environment[Key.gitTerminalPrompt] = disabled
        environment[Key.gitConfigNoSystem] = enabled
        environment[Key.gitSSHCommand] = gitSSHCommand
        return environment
    }

    /// The ssh environment (§5.10, §8 D1–D2).
    public static func ssh(identity: ProcessIdentityModel, shell: ShellEnvironmentModel) -> [String: String] {
        var environment: [String: String] = [
            Key.home: identity.home,
            Key.user: identity.user,
            Key.path: shell.resolvedPATH,
            Key.lang: GHConstants.processLanguage,
        ]
        environment[Key.sshAuthSock] = shell.sshAuthSock ?? identity.sshAuthSocket
        return environment
    }

    /// The environment of the login-shell probe (§8 A2): identity, the system PATH and the
    /// recursion marker. Nothing the shell could forward.
    public static func shellProbe(identity: ProcessIdentityModel) -> [String: String] {
        [
            Key.home: identity.home,
            Key.user: identity.user,
            Key.logname: identity.user,
            Key.tmpdir: identity.temporaryDirectory,
            Key.path: GHConstants.systemPATH,
            Key.lang: GHConstants.processLanguage,
            Key.term: dumbTerminal,
            Key.resolvingEnvironment: enabled,
        ]
    }

    /// `GIT_SSH_COMMAND`: `/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=15`.
    public static var gitSSHCommand: String {
        "\(GHConstants.sshPath) -o BatchMode=yes -o ConnectTimeout=\(Timeouts.gitSSHConnectTimeoutSeconds)"
    }

    /// The token as an environment string. Rejects anything but printable ASCII so a malformed
    /// token can never inject another variable.
    static func tokenString(_ token: SecretBytes) throws(GHError) -> String {
        let isPrintable = token.withUnsafeBytes { bytes in
            !bytes.isEmpty && bytes.allSatisfy { $0 > asciiSpace && $0 < asciiDelete }
        }
        guard isPrintable else { throw .tokenRevoked }
        return token.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
    }

    private static let asciiSpace: UInt8 = 0x20
    private static let asciiDelete: UInt8 = 0x7f
}
