import Darwin
import Foundation
import VaultCore

/// A variable the shell probe reports by name only (v0.3.1): whether the user's shell exports it
/// with a non-empty value. The value is never printed, read or kept.
public enum ShellVariableName: String, Sendable, Hashable, CaseIterable, Codable, Comparable {
    case ghToken = "GH_TOKEN"
    case githubToken = "GITHUB_TOKEN"
    case ghConfigDir = "GH_CONFIG_DIR"
    case xdgConfigHome = "XDG_CONFIG_HOME"
    case ghHost = "GH_HOST"

    /// The token variables gh prefers over its stored accounts. FX Vault never passes them to
    /// gh; while one is exported, Terminal's `gh auth status` shows that token and
    /// `gh auth login` refuses to store an account.
    public static let tokenVariables: [ShellVariableName] = [.ghToken, .githubToken]

    public static func < (lhs: ShellVariableName, rhs: ShellVariableName) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Which attempt of the shell probe answered (§8 A2, v0.3.1).
public enum ShellProbeMode: String, Sendable, Hashable, Codable {
    /// An interactive login shell (`-i -l -c`; csh and tcsh `-i -c`): it reads `~/.zshrc`,
    /// `~/.bashrc` (through the profile) and fish's interactive blocks, like Terminal.
    case interactive
    /// The fallback after the interactive shell timed out or printed no markers (`-l -c`; csh
    /// and tcsh `-c`).
    case login
    /// Neither attempt printed the markers, or the probe has not run.
    case failed
}

/// The allowlisted variables captured from the user's shell (tasks/todo.md §8 A2).
///
/// GUI apps do not inherit the shell's PATH, `GH_CONFIG_DIR` or `XDG_*`; these are the only
/// values FX Vault ever reads from the shell. Since v0.3.1 it also records the gh the shell's
/// PATH finds and which of ``ShellVariableName`` are set (names only, never values).
public struct ShellEnvironmentModel: Sendable, Hashable {
    /// The captured PATH, reduced to absolute directories.
    public var path: String?
    public var ghConfigDir: String?
    public var xdgConfigHome: String?
    public var xdgCacheHome: String?
    public var xdgStateHome: String?
    public var sshAuthSock: String?
    /// The gh the shell's PATH finds (`command -v gh`): the gh Terminal runs. An absolute path
    /// whose last component is `gh`; nil when the shell finds none or the probe failed.
    public var ghPath: String?
    /// The ``ShellVariableName``s the shell exports with a non-empty value. Names only.
    public var setVariables: Set<ShellVariableName>
    /// Which attempt answered.
    public var probeMode: ShellProbeMode
    /// The shell that was probed; nil for a model built without running the probe.
    public var shellPath: String?

    public init(
        path: String? = nil,
        ghConfigDir: String? = nil,
        xdgConfigHome: String? = nil,
        xdgCacheHome: String? = nil,
        xdgStateHome: String? = nil,
        sshAuthSock: String? = nil,
        ghPath: String? = nil,
        setVariables: Set<ShellVariableName> = [],
        probeMode: ShellProbeMode = .failed,
        shellPath: String? = nil
    ) {
        self.path = path
        self.ghConfigDir = ghConfigDir
        self.xdgConfigHome = xdgConfigHome
        self.xdgCacheHome = xdgCacheHome
        self.xdgStateHome = xdgStateHome
        self.sshAuthSock = sshAuthSock
        self.ghPath = ghPath
        self.setVariables = setVariables
        self.probeMode = probeMode
        self.shellPath = shellPath
    }

    /// Nothing captured (the probe failed or has not run).
    public static let empty = ShellEnvironmentModel()

    /// The PATH children get: the captured one, or ``GHConstants/defaultPATH``.
    public var resolvedPATH: String {
        path ?? GHConstants.defaultPATH
    }

    /// The PATH directories in order.
    public var pathDirectories: [String] {
        resolvedPATH.split(separator: ":").map(String.init)
    }

    /// The token variables (`GH_TOKEN`, `GITHUB_TOKEN`) the shell exports, in that order.
    public var exportedTokenVariables: [ShellVariableName] {
        ShellVariableName.tokenVariables.filter(setVariables.contains)
    }
}

/// Captures ``ShellEnvironmentModel`` by running the user's shell once (§8 A2).
///
/// - The script only runs absolute-path external commands separated by `;`, so the same text
///   works in sh, bash, zsh, ksh, fish and csh. For each allowlisted key it prints
///   `KEY=` + `printenv KEY` + NUL between the markers `__FXV_B__` and `__FXV_E__`; shell
///   start-up noise outside the markers is ignored.
/// - One of those commands is `/bin/sh -c '<report>'` (``reportScript``), which inherits what
///   the user's shell exports and prints `FXV_GH=` + `command -v gh`, then `FXV_SET=<NAME>` for
///   each ``ShellVariableName`` that is set and non-empty. The test is sh's `[` builtin: a value
///   never reaches stdout, an argv or a file.
/// - Only allowlisted keys are ever requested, and the parser keeps only allowlisted keys, an
///   absolute `…/gh` path and exact variable names, even if the output contains other text.
/// - Flags (v0.3.1): the interactive login shell first (`-i -l -c`), so settings that live only
///   in `~/.zshrc` (PATH additions, `GH_CONFIG_DIR`, `XDG_CONFIG_HOME`) are seen exactly as
///   Terminal sees them; then `-l -c` when the first attempt timed out or printed no markers.
///   csh-family shells reject `-l` together with `-c`, so they run `-i -c`, then `-c`.
/// - Environment: identity, the system PATH, `TERM=dumb` and `FXVAULT_RESOLVING_ENV=1`
///   (``ProcessEnvironmentBuilder/shellProbe(identity:)``); stdin is empty; 5 s per attempt.
public struct ShellEnvironmentResolver: Sendable {
    /// The keys captured, in output order.
    public static let capturedKeys: [String] = [
        ProcessEnvironmentBuilder.Key.path,
        ProcessEnvironmentBuilder.Key.ghConfigDir,
        ProcessEnvironmentBuilder.Key.xdgConfigHome,
        ProcessEnvironmentBuilder.Key.xdgCacheHome,
        ProcessEnvironmentBuilder.Key.xdgStateHome,
        ProcessEnvironmentBuilder.Key.sshAuthSock,
    ]

    static let beginMarker = "__FXV_B__"
    static let endMarker = "__FXV_E__"
    /// The entry carrying `command -v gh`.
    static let ghPathKey = "FXV_GH"
    /// The entries naming a set ``ShellVariableName``.
    static let flagKey = "FXV_SET"
    private static let printfPath = "/usr/bin/printf"
    private static let printenvPath = "/usr/bin/printenv"
    private static let posixShellPath = "/bin/sh"
    private static let defaultShell = "/bin/zsh"
    private static let ghExecutableName = "gh"
    private static let entrySeparator: Character = "\0"
    private static let pathSeparator: Character = ":"

    /// The shell family, which decides the flags.
    public enum ShellFlavor: Sendable, Hashable {
        case posix
        case fish
        case csh

        /// Detects the flavor from the shell's file name.
        public init(shellPath: String) {
            switch URL(fileURLWithPath: shellPath).lastPathComponent {
            case "fish": self = .fish
            case "csh", "tcsh": self = .csh
            default: self = .posix
            }
        }

        /// argv after the shell path for the interactive attempt and the login fallback.
        func arguments(script: String, interactive: Bool) -> [String] {
            switch (self, interactive) {
            case (.posix, false), (.fish, false): ["-l", "-c", script]
            case (.posix, true), (.fish, true): ["-i", "-l", "-c", script]
            case (.csh, false): ["-c", script]
            case (.csh, true): ["-i", "-c", script]
            }
        }
    }

    /// The attempts in order: the interactive login shell first (v0.3.1).
    public static let attemptOrder: [ShellProbeMode] = [.interactive, .login]

    private let runner: any CommandRunning
    private let identity: ProcessIdentityModel
    /// The shell that is probed.
    public let shellPath: String
    private let workingDirectory: URL

    /// `shellPath` defaults to the user's login shell from the password database.
    public init(
        runner: any CommandRunning,
        identity: ProcessIdentityModel,
        workingDirectory: URL,
        shellPath: String? = nil
    ) {
        self.runner = runner
        self.identity = identity
        self.workingDirectory = workingDirectory
        self.shellPath = shellPath ?? Self.loginShellPath()
    }

    /// Runs the probe (interactive, then login if needed). Returns a model with
    /// ``ShellProbeMode/failed`` and nothing captured when both attempts fail; never throws
    /// except on cancellation.
    public func resolve() async throws(CommandRunnerError) -> ShellEnvironmentModel {
        let flavor = ShellFlavor(shellPath: shellPath)
        for mode in Self.attemptOrder {
            if var model = try await probe(flavor: flavor, interactive: mode == .interactive) {
                model.probeMode = mode
                model.shellPath = shellPath
                return model
            }
        }
        return ShellEnvironmentModel(probeMode: .failed, shellPath: shellPath)
    }

    private func probe(flavor: ShellFlavor, interactive: Bool) async throws(CommandRunnerError)
        -> ShellEnvironmentModel?
    {
        let spec = CommandSpec(
            executableURL: URL(fileURLWithPath: shellPath),
            arguments: flavor.arguments(script: Self.script, interactive: interactive),
            environment: ProcessEnvironmentBuilder.shellProbe(identity: identity),
            workingDirectory: workingDirectory,
            timeout: Timeouts.shellProbe
        )
        let result: CommandResult
        do {
            result = try await runner.run(spec)
        } catch .cancelled {
            throw .cancelled
        } catch {
            return nil
        }
        defer { result.stdout.wipe() }
        guard !result.didTimeOut else { return nil }
        let output = result.stdout.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        return Self.parse(output)
    }

    /// The probe script (constant; no user input).
    public static var script: String {
        var commands = ["\(printfPath) '%s' \(beginMarker)"]
        for key in capturedKeys {
            commands.append("\(printfPath) '%s=' \(key)")
            commands.append("\(printenvPath) \(key)")
            commands.append("\(printfPath) '\\0'")
        }
        commands.append("\(posixShellPath) -c '\(reportScript)'")
        commands.append("\(printfPath) '%s' \(endMarker)")
        return commands.joined(separator: "; ")
    }

    /// The POSIX sh part of ``script`` (single-quoted there, so it contains no `'`, and no `!`
    /// for csh history): `FXV_GH=` + `command -v gh` + NUL, then `FXV_SET=<NAME>` + NUL for each
    /// ``ShellVariableName`` that is set and non-empty.
    static var reportScript: String {
        var commands = [
            "\(printfPath) \"%s\" \(ghPathKey)=",
            "command -v \(ghExecutableName)",
            "\(printfPath) \"\\0\"",
        ]
        for name in ShellVariableName.allCases {
            commands.append("[ -n \"${\(name.rawValue)-}\" ] && \(printfPath) \"%s\\0\" \(flagKey)=\(name.rawValue)")
        }
        commands.append("exit 0")
        return commands.joined(separator: "; ")
    }

    /// Extracts the allowlisted values between the markers, or nil when the markers are
    /// missing. Values with control characters are dropped; PATH keeps only absolute
    /// directories; the other keys must be absolute paths. `FXV_GH` must be an absolute path
    /// ending in `/gh`; `FXV_SET` entries must name a ``ShellVariableName`` exactly (the model
    /// stores the enum case, never text from the output).
    public static func parse(_ output: String) -> ShellEnvironmentModel? {
        guard let begin = output.range(of: beginMarker),
              let end = output.range(of: endMarker, range: begin.upperBound..<output.endIndex)
        else { return nil }
        let body = output[begin.upperBound..<end.lowerBound]
        var values: [String: String] = [:]
        var ghPath: String?
        var setVariables: Set<ShellVariableName> = []
        for entry in body.split(separator: entrySeparator, omittingEmptySubsequences: true) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[entry.startIndex..<equals])
            var value = String(entry[entry.index(after: equals)...])
            if value.hasSuffix("\n") {
                value.removeLast()
            }
            switch key {
            case flagKey:
                if let name = ShellVariableName(rawValue: value) {
                    setVariables.insert(name)
                }
            case ghPathKey:
                if ghPath == nil {
                    ghPath = sanitizedGHPath(value)
                }
            default:
                guard capturedKeys.contains(key), values[key] == nil else { continue }
                if let sanitized = sanitize(value, key: key) {
                    values[key] = sanitized
                }
            }
        }
        return ShellEnvironmentModel(
            path: values[ProcessEnvironmentBuilder.Key.path],
            ghConfigDir: values[ProcessEnvironmentBuilder.Key.ghConfigDir],
            xdgConfigHome: values[ProcessEnvironmentBuilder.Key.xdgConfigHome],
            xdgCacheHome: values[ProcessEnvironmentBuilder.Key.xdgCacheHome],
            xdgStateHome: values[ProcessEnvironmentBuilder.Key.xdgStateHome],
            sshAuthSock: values[ProcessEnvironmentBuilder.Key.sshAuthSock],
            ghPath: ghPath,
            setVariables: setVariables
        )
    }

    private static func sanitize(_ value: String, key: String) -> String? {
        guard !value.isEmpty, UnicodeScalarPolicy.firstViolation(in: value) == nil else { return nil }
        if key == ProcessEnvironmentBuilder.Key.path {
            let directories = value.split(separator: pathSeparator).filter { $0.hasPrefix("/") }
            return directories.isEmpty ? nil : directories.joined(separator: String(pathSeparator))
        }
        return value.hasPrefix("/") ? value : nil
    }

    /// `command -v gh` answers with a path for a file in PATH, and with other text for an alias
    /// or function: keep only an absolute path to a file named `gh`.
    private static func sanitizedGHPath(_ value: String) -> String? {
        guard value.hasPrefix("/"),
              value.utf8.count <= Int(PATH_MAX),
              UnicodeScalarPolicy.firstViolation(in: value) == nil,
              (value as NSString).lastPathComponent == ghExecutableName
        else { return nil }
        return value
    }

    private static func loginShellPath() -> String {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else {
            return defaultShell
        }
        let path = String(cString: shell)
        guard path.hasPrefix("/"), access(path, X_OK) == 0 else { return defaultShell }
        return path
    }
}
