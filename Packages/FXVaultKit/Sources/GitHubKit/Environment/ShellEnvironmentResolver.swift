import Darwin
import Foundation
import VaultCore

/// The allowlisted variables captured from the user's login shell (tasks/todo.md §8 A2).
///
/// GUI apps do not inherit the shell's PATH, `GH_CONFIG_DIR` or `XDG_*`; these are the only
/// values FX Vault ever reads from the shell.
public struct ShellEnvironmentModel: Sendable, Hashable {
    /// The captured PATH, reduced to absolute directories.
    public var path: String?
    public var ghConfigDir: String?
    public var xdgConfigHome: String?
    public var xdgCacheHome: String?
    public var xdgStateHome: String?
    public var sshAuthSock: String?

    public init(
        path: String? = nil,
        ghConfigDir: String? = nil,
        xdgConfigHome: String? = nil,
        xdgCacheHome: String? = nil,
        xdgStateHome: String? = nil,
        sshAuthSock: String? = nil
    ) {
        self.path = path
        self.ghConfigDir = ghConfigDir
        self.xdgConfigHome = xdgConfigHome
        self.xdgCacheHome = xdgCacheHome
        self.xdgStateHome = xdgStateHome
        self.sshAuthSock = sshAuthSock
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
}

/// Captures ``ShellEnvironmentModel`` by running the user's login shell once (§8 A2).
///
/// - The script only runs absolute-path external commands separated by `;`, so the same text
///   works in sh, bash, zsh, ksh, fish and csh. For each allowlisted key it prints
///   `KEY=` + `printenv KEY` + NUL between the markers `__FXV_B__` and `__FXV_E__`; shell
///   start-up noise outside the markers is ignored.
/// - Only allowlisted keys are ever requested, and the parser keeps only allowlisted keys even
///   if the output contains others.
/// - Flags: `-l -c` first, then `-i -l -c` when the first run yields no markers. csh-family
///   shells reject `-l` together with `-c`, so they run `-c` then `-i -c`.
/// - Environment: identity, the system PATH, `TERM=dumb` and `FXVAULT_RESOLVING_ENV=1`
///   (``ProcessEnvironmentBuilder/shellProbe(identity:)``); stdin is empty; 5 s timeout.
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
    private static let printfPath = "/usr/bin/printf"
    private static let printenvPath = "/usr/bin/printenv"
    private static let defaultShell = "/bin/zsh"
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

        /// argv after the shell path for the first attempt and the interactive fallback.
        func arguments(script: String, interactive: Bool) -> [String] {
            switch (self, interactive) {
            case (.posix, false), (.fish, false): ["-l", "-c", script]
            case (.posix, true), (.fish, true): ["-i", "-l", "-c", script]
            case (.csh, false): ["-c", script]
            case (.csh, true): ["-i", "-c", script]
            }
        }
    }

    private let runner: any CommandRunning
    private let identity: ProcessIdentityModel
    private let shellPath: String
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

    /// Runs the probe (`-l`, then `-i -l` if needed). Returns ``ShellEnvironmentModel/empty``
    /// when both attempts fail; never throws except on cancellation.
    public func resolve() async throws(CommandRunnerError) -> ShellEnvironmentModel {
        let flavor = ShellFlavor(shellPath: shellPath)
        for interactive in [false, true] {
            if let model = try await probe(flavor: flavor, interactive: interactive) {
                return model
            }
        }
        return .empty
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
        commands.append("\(printfPath) '%s' \(endMarker)")
        return commands.joined(separator: "; ")
    }

    /// Extracts the allowlisted values between the markers, or nil when the markers are
    /// missing. Values with control characters are dropped; PATH keeps only absolute
    /// directories; the other keys must be absolute paths.
    public static func parse(_ output: String) -> ShellEnvironmentModel? {
        guard let begin = output.range(of: beginMarker),
              let end = output.range(of: endMarker, range: begin.upperBound..<output.endIndex)
        else { return nil }
        let body = output[begin.upperBound..<end.lowerBound]
        var values: [String: String] = [:]
        for entry in body.split(separator: entrySeparator, omittingEmptySubsequences: true) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[entry.startIndex..<equals])
            guard capturedKeys.contains(key), values[key] == nil else { continue }
            var value = String(entry[entry.index(after: equals)...])
            if value.hasSuffix("\n") {
                value.removeLast()
            }
            if let sanitized = sanitize(value, key: key) {
                values[key] = sanitized
            }
        }
        return ShellEnvironmentModel(
            path: values[ProcessEnvironmentBuilder.Key.path],
            ghConfigDir: values[ProcessEnvironmentBuilder.Key.ghConfigDir],
            xdgConfigHome: values[ProcessEnvironmentBuilder.Key.xdgConfigHome],
            xdgCacheHome: values[ProcessEnvironmentBuilder.Key.xdgCacheHome],
            xdgStateHome: values[ProcessEnvironmentBuilder.Key.xdgStateHome],
            sshAuthSock: values[ProcessEnvironmentBuilder.Key.sshAuthSock]
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

    private static func loginShellPath() -> String {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else {
            return defaultShell
        }
        let path = String(cString: shell)
        guard path.hasPrefix("/"), access(path, X_OK) == 0 else { return defaultShell }
        return path
    }
}
